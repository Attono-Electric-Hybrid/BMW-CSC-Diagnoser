use strict;
use warnings;
use Test::More;

# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/../lib";

use CAN::Adapter::Lawicel;
use Test::MockModule;

# We need to mock Device::SerialPort to avoid needing real hardware
my $serial_mock = Test::MockModule->new('Device::SerialPort');
my $termios_mock = Test::MockModule->new('Linux::Termios2');

my $written_data;
my $read_buffer = '';
# Create a real, but in-memory, filehandle to be blessed for the mock.
# This allows the built-in fileno() to work on our mock object.
open my $mock_fh, '+>', \my $in_memory_buffer;

# Mock Linux::Termios2 to do nothing, as we don't test low-level setup here.
$termios_mock->mock('new' => sub { bless {}, shift });
$termios_mock->mock('set' => sub {1});

$serial_mock->mock(
    'new'       => sub {
        my $class = shift;
        # The real object is a hash containing the file descriptor (FD).
        # We mock this structure to allow the main code to access $port->{FD}.
        my $mock_obj = { FD => fileno($mock_fh) };
        return bless $mock_obj, $class;
    },
    'FILENO' => sub {
        my $self = shift;
        # The real FILENO method returns the internal file descriptor.
        return $self->{FD};
    },
    'read_char_time' => sub {1},
    'read_const_time' => sub {1},
    'write_settings' => sub {1},
    'write'     => sub {
        my ($self, $data) = @_;
        $written_data = $data;
        # If this is a settings command, simulate the adapter sending back an ACK
        if ($data =~ /^\xaa\x55\x12/) {
            $read_buffer .= "\r";
        }
        # If this is a close command, simulate the adapter sending back an ACK
        elsif ($data eq "C\r") {
            $read_buffer .= "\r";
        }
        # If this is a version command, simulate the version response
        elsif ($data eq "V\r") {
            $read_buffer = "V9876\r";
        }
        return length($data);
    },
    'read' => sub {
        my ($self, $count) = @_;
        my $chunk = substr($read_buffer, 0, $count, '');
        return (length($chunk), $chunk);
    },
    'purge_rx' => sub {1},
    'close' => sub {1},
);

# Test 1: Can't open bus if adapter isn't open
my $adapter = CAN::Adapter::Lawicel->new();
eval { $adapter->open_bus() };
like($@, qr/Adapter is not open/, 'open_bus() dies if adapter is not open');

# Test 2: Can open the bus
$adapter->open();
ok($adapter->{is_open}, 'Adapter is now open');

# Test 3: open_bus() with default speed (500k)
ok($adapter->open_bus(), 'open_bus() succeeds and gets ACK');
is(length($written_data), 21, 'Wrote 21 bytes for settings command');

# Expected frame for 500k speed (0x03)
my @payload = (0x12, 0x03, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x01, 0, 0, 0, 0);
my $checksum = 0;
$checksum += $_ for @payload;
$checksum &= 0xff;
my $expected_frame = pack('C C C*', 0xaa, 0x55, @payload, $checksum);

is($written_data, $expected_frame, 'Correct command frame sent for 500k');

# Test 4: open_bus() with a different speed (1M)
ok($adapter->open_bus(can_speed => 1000000), 'open_bus() with 1M speed succeeds');
is(length($written_data), 21, 'Wrote 21 bytes for 1M speed');

@payload = (0x12, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x01, 0, 0, 0, 0);
$checksum = 0;
$checksum += $_ for @payload;
$checksum &= 0xff;
$expected_frame = pack('C C C*', 0xaa, 0x55, @payload, $checksum);
is($written_data, $expected_frame, 'Correct command frame sent for 1M');

# Test 5: get_version()
my $version;
lives_ok { $version = $adapter->get_version() } 'get_version() does not die on success';
is($version, "V9876\r", 'get_version() returns correct version string');

# Test 6: close_bus()
lives_ok { ok($adapter->close_bus(), 'close_bus() returns true on ACK') } 'close_bus() does not die';
is($written_data, "C\r", 'close_bus() sends the correct command');

# Test 7: close() works
$adapter->close();
is($adapter->{is_open}, 0, 'Adapter is_open is false after close()');
is($adapter->{handle}, undef, 'Adapter handle is undef after close()');

done_testing();