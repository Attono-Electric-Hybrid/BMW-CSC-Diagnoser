package CAN::Adapter::Lawicel;

use 5.006;
use strict;
use warnings;

use Device::SerialPort;
use Time::HiRes qw(time sleep);

our $VERSION = '0.01';

# Map user-friendly speed in bps to the byte code required by the adapter.
my %CAN_SPEED_MAP = (
    1000000 => 0x01,
    800000  => 0x02,
    500000  => 0x03,
    400000  => 0x04,
    250000  => 0x05,
    200000  => 0x06,
    125000  => 0x07,
    100000  => 0x08,
    50000   => 0x09,
    20000   => 0x0a,
    10000   => 0x0b,
    5000    => 0x0c,
);

=head1 NAME

CAN::Adapter::Lawicel - Interface to Lawicel-style CAN USB adapters.

=head1 VERSION

Version 0.01

=cut


=head1 SYNOPSIS

    use CAN::Adapter::Lawicel;

    my $adapter = CAN::Adapter::Lawicel->new(
        device => '/dev/ttyUSB0',
    );

    # ... more to come

=head1 SUBROUTINES/METHODS

=head2 new

Creates a new adapter object.

=over

=item * C<device>

The path to the serial device (e.g., '/dev/ttyUSB0').

=item * C<baudrate>

The serial baud rate for the adapter. Defaults to 2000000.

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        device   => $args{device}   || '/dev/ttyUSB0',
        baudrate => $args{baudrate} || 2000000,
        handle   => undef, # Will hold the serial port handle
        is_open  => 0,
        _in_buffer => '',
    };

    return bless $self, $class;
}

=head2 open

Opens the connection to the serial device.

Dies on failure. Returns true on success.

=cut

sub open {
    my ($self) = @_;
    return 1 if $self->{is_open};

    my $port = Device::SerialPort->new($self->{device})
        || die "Can't open $self->{device}: $!";

    $port->baudrate($self->{baudrate}) || die "Can't set baudrate to $self->{baudrate}: $!";
    $port->databits(8)                 || die "Can't set databits to 8: $!";
    $port->parity("none")              || die "Can't set parity to none: $!";
    # The original C code clears the CSTOPB flag (opts.c_cflag &= ~CSTOPB),
    # which means it uses one stop bit.
    $port->stopbits(1)                 || die "Can't set stopbits to 1: $!";
    $port->handshake("none")            || die "Can't set handshake to none: $!";

    # Set timeouts for non-blocking reads, mimicking O_NONBLOCK in the C code.
    # A 1ms constant timeout is effectively non-blocking.
    $port->read_const_time(1); # in ms
    $port->read_char_time(0);  # in ms
    # Disable output post-processing to send raw bytes, matching cfmakeraw() in C.
    $port->stty_opost(0);
    # Disable CR->NL translation on input, also part of cfmakeraw().
    # This is critical for receiving the '\r' ACK character correctly.
    $port->stty_icrnl(0);

    $port->write_settings()            || die "Can't apply serial port settings: $!";

    # Purge any old data from the OS and adapter buffers and wait a moment.
    $port->purge_rx();
    sleep(0.1);

    $self->{handle}  = $port;
    $self->{is_open} = 1;

    return 1;
}

=head2 open_bus

Sends the settings command to the adapter to open the CAN bus at a specific speed.

=over

=item * C<can_speed>

The CAN bus speed in bps (e.g., 500000). Defaults to 500000.

=back

Dies on failure. Returns true on success.

=cut

sub open_bus {
    my ($self, %args) = @_;
    die "Adapter is not open. Call open() first." unless $self->{is_open};
    my $speed = $args{can_speed} || 500000;

    # Purge any stale data from OS/adapter buffers right before we send our command
    # and expect a specific response. This is crucial on an active bus.
    $self->{handle}->purge_rx();
    $self->{_in_buffer} = '';

    my $speed_code = $CAN_SPEED_MAP{$speed}
        or die "Unsupported CAN speed: $speed";

    # This command is based on command_settings() in canusb.c
    my @cmd_payload = (
        0x12,       # Settings command
        $speed_code,
        0x01,       # Frame type: Standard
        0, 0, 0, 0, # Filter ID (not used)
        0, 0, 0, 0, # Mask ID (not used)
        0x00,       # Mode: Normal (0x01 for listen-only)
        0x00,       # Unused byte, to match C implementation's 18-byte payload
        0x01,       # Constant
        0, 0, 0, 0  # Unused
    );

    my $checksum = _generate_checksum(@cmd_payload);
    my $frame = pack('C C C*', 0xaa, 0x55, @cmd_payload, $checksum);

    my $written = $self->{handle}->write($frame);
    die "Failed to write settings command to adapter: $!" unless $written == length($frame);

    # Wait for an ACK (\r) from the device to confirm the command was accepted.
    my $timeout = 1; # 1 second timeout
    my $end_time = time() + $timeout;

    while (time() < $end_time) {
        # This is non-blocking, so it's safe in a loop
        $self->fill_buffer(); 
        # Process all frames in the buffer, looking for the ACK. This is much
        # more efficient than the previous "check-one-and-sleep" approach.
        while (my $response = $self->read_frame()) {
            return 1 if $response->{type} eq 'ack';
            # Other frames (data, error) are ignored during this handshake.
        }
        sleep(0.05); # 50ms sleep to not busy-wait
    }

    # If we get here, we timed out.
    die "Did not receive ACK from adapter after sending settings within ${timeout}s. Check connection/speed.";
}

=head2 close_bus

Sends the command to close the CAN bus. This can be useful to reset the
adapter's state before sending other commands.

Returns true if an ACK was received, false otherwise. Does not die on timeout.

=cut

sub close_bus {
    my ($self) = @_;
    die "Adapter is not open. Call open() first." unless $self->{is_open};

    # Purge buffers to ensure we're reading a fresh response
    $self->{handle}->purge_rx();
    $self->{_in_buffer} = '';

    my $cmd = "C\r";
    my $written = $self->{handle}->write($cmd);
    die "Failed to write close command to adapter: $!" unless $written == length($cmd);

    # Wait for an ACK (\r) from the device to confirm.
    my $timeout = 0.5; # Half a second is plenty
    my $end_time = time() + $timeout;

    while (time() < $end_time) {
        $self->fill_buffer();
        while (my $response = $self->read_frame()) {
            return 1 if $response->{type} eq 'ack';
        }
        sleep(0.05);
    }
    
    # It's okay if we don't get an ACK, the adapter might have been closed already.
    # This is a best-effort reset.
    return 0;
}

=head2 send

Sends a data frame to the CAN bus.

=over

=item * C<id>

The CAN ID as a hex string (e.g., '1E0').

=item * C<data>

The data payload as a hex string (e.g., '5ed00000000070d3').

=back

Returns true on success, false on failure.

=cut

sub send {
    my ($self, %args) = @_;
    die "Adapter is not open. Call open() first." unless $self->{is_open};

    my $id_hex = $args{id} or die "send() requires 'id'";
    my $data_hex = $args{data} or die "send() requires 'data'";

    my $id = hex($id_hex);
    my @data_bytes = map { hex } ($data_hex =~ m/../g);
    my $dlc = @data_bytes;

    die "DLC must be between 0 and 8" if $dlc > 8;

    # For now, assume standard frames as that's all the system uses
    my $info_byte = 0xC0 | $dlc; # 0b11000000 | DLC
    
    my @frame_bytes;
    push @frame_bytes, 0xaa;
    push @frame_bytes, $info_byte;
    push @frame_bytes, $id & 0xFF; # LSB
    push @frame_bytes, ($id >> 8) & 0xFF; # MSB
    push @frame_bytes, @data_bytes;
    push @frame_bytes, 0x55;

    my $frame_packed = pack('C*', @frame_bytes);
    my $written = $self->{handle}->write($frame_packed);
    
    return $written == length($frame_packed);
}

=head2 fill_buffer

Reads available data from the serial port and adds it to the internal buffer.
This is intended to be called when IO::Select indicates the handle is readable.

Returns the number of bytes read, 0 on timeout, or undef on error.

=cut

sub fill_buffer {
    my ($self) = @_;
    my ($count, $data) = $self->{handle}->read(256);
    if (defined $count && $count > 0) {
        $self->{_in_buffer} .= $data;
    }
    return $count;
}

=head2 read_frame

Attempts to parse a single, complete CAN frame from the internal buffer.

Returns a hashref representing the frame, or undef if no complete frame is available.

=cut

sub read_frame {
    my ($self) = @_;

    # Return undef if buffer is empty, signalling to the caller to fill it.
    return undef if length($self->{_in_buffer}) == 0;

    my $first_char = substr($self->{_in_buffer}, 0, 1);

    # Handle single-character ACK/NACK responses from the adapter
    if ($first_char eq "\r") {
        substr($self->{_in_buffer}, 0, 1, ''); # Consume the character
        return { type => 'ack' };
    }
    if ($first_char eq "\a") {
        substr($self->{_in_buffer}, 0, 1, ''); # Consume the character
        return { type => 'nack' };
    }

    # Handle multi-byte data frames, which start with 0xaa
    if ($first_char eq "\xaa") {
        # We need at least 2 bytes for a minimal header. If not, wait for more data.
        return undef if length($self->{_in_buffer}) < 2;

        my $info_byte = unpack('C', substr($self->{_in_buffer}, 1, 1));

        if (($info_byte >> 4) == 0x0C) { # This is a standard CAN data frame
            my $dlc = $info_byte & 0x0F;
            my $expected_len = $dlc + 5; # start(1)+info(1)+id(2)+dlc+end(1)
            
            # If we don't have the full frame yet, wait for more data.
            return undef if length($self->{_in_buffer}) < $expected_len;

            my $frame_raw = substr($self->{_in_buffer}, 0, $expected_len, '');

            if (substr($frame_raw, -1, 1) ne "\x55") {
                return { type => 'error', reason => 'corrupted', details => 'Corrupted data from adapter (bad end byte)', raw => unpack('H*', $frame_raw) };
            }

            # This is a valid frame, parse and return it.
            my @bytes = unpack('C*', $frame_raw);
            my $id = ($bytes[3] << 8) | $bytes[2];
            my @data_bytes = @bytes[4 .. (4 + $dlc - 1)];
            return { type => 'data', id => sprintf("%03X", $id), dlc => $dlc, data => \@data_bytes };
        }
        else {
            # It started with 0xaa but isn't a known frame type. Report an error.
            my $frame_raw = substr($self->{_in_buffer}, 0, 2, '');
            return { type => 'error', reason => 'unknown_type', details => 'Unrecognized frame type from adapter', raw => unpack('H*', $frame_raw) };
        }
    }

    # If we get here, the first character is not a known start of a frame. It's garbage.
    my $garbage = substr($self->{_in_buffer}, 0, 1, '');
    return { type => 'error', reason => 'garbage', details => 'Unexpected data from adapter', raw => unpack('H*', $garbage) };
}

=head2 get_version

Requests the firmware version from the adapter. This is a simple way to test
basic communication.

Returns the version string on success, or dies on timeout.

=cut

sub get_version {
    my ($self) = @_;
    die "Adapter is not open. Call open() first." unless $self->{is_open};

    # Purge buffers to ensure we're reading a fresh response
    $self->{handle}->purge_rx();
    $self->{_in_buffer} = '';

    my $cmd = "V\r";
    my $written = $self->{handle}->write($cmd);
    die "Failed to write version command to adapter: $!" unless $written == length($cmd);

    my $timeout = 1; # 1 second timeout
    my $end_time = time() + $timeout;
    my $version_string;

    while (time() < $end_time) {
        $self->fill_buffer();
        # The response is not a standard frame, so we check the raw buffer
        if ($self->{_in_buffer} =~ s/^(V[^\r]*\r)//) {
            $version_string = $1;
            last;
        }
        sleep(0.05);
    }

    die "Did not receive a version response from adapter within ${timeout}s" unless $version_string;
    
    return $version_string;
}

=head2 get_handle

Returns the underlying Device::SerialPort file handle.

=cut

sub get_handle {
    my ($self) = @_;
    return $self->{handle};
}

=head2 close

Closes the connection to the serial device.

=cut

sub close {
    my ($self) = @_;
    if ($self->{is_open}) {
        $self->{handle}->close();
        $self->{handle} = undef;
        $self->{is_open} = 0;
    }
    return 1;
}

sub _generate_checksum {
    my @bytes = @_;
    my $checksum = 0;
    $checksum += $_ for @bytes;
    return $checksum & 0xff;
}

=head1 AUTHOR

Gemini Code Assist

=cut

1;