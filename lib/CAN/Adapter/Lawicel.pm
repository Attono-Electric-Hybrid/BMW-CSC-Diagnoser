package CAN::Adapter::Lawicel;

use 5.006;
use strict;
use warnings;

use Device::SerialPort;

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
    $port->stopbits(1)                 || die "Can't set stopbits to 1: $!";
    $port->handshake("none")            || die "Can't set handshake to none: $!";

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

    my $speed_code = $CAN_SPEED_MAP{$speed}
        or die "Unsupported CAN speed: $speed";

    # This command is based on command_settings() in canusb.c
    my @cmd_payload = (
        0x12,       # Settings command
        $speed_code,
        0x01,       # Frame type: Standard
        0, 0, 0, 0, # Filter ID (not used)
        0, 0, 0, 0, # Mask ID (not used)
        0x00,       # Mode: Normal
        0x01,       # Constant
        0, 0, 0, 0  # Unused
    );

    my $checksum = _generate_checksum(@cmd_payload);
    my $frame = pack('C C C*', 0xaa, 0x55, @cmd_payload, $checksum);

    my $written = $self->{handle}->write($frame);
    die "Failed to write settings command to adapter: $!" unless $written == length($frame);

    # A more robust implementation might wait for an ACK from the device here.
    return 1;
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