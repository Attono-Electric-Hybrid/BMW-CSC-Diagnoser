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

my $written_data;
$serial_mock->mock(
    'new'       => sub { bless {}, shift },
    'baudrate'  => sub {1},
    'databits'  => sub {1},
    'parity'    => sub {1},
    'stopbits'  => sub {1},
    'handshake' => sub {1},
    'write'     => sub {
        my ($self, $data) = @_;
        $written_data = $data;
        return length($data);
    },
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
$adapter->open_bus();
is(length($written_data), 20, 'Wrote 20 bytes for settings command');

# Expected frame for 500k speed (0x03)
my @payload = (0x12, 0x03, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x01, 0, 0, 0, 0);
my $checksum = 0;
$checksum += $_ for @payload;
$checksum &= 0xff;
my $expected_frame = pack('C C C*', 0xaa, 0x55, @payload, $checksum);

is($written_data, $expected_frame, 'Correct command frame sent for 500k');

# Test 4: open_bus() with a different speed (1M)
$adapter->open_bus(can_speed => 1000000);
is(length($written_data), 20, 'Wrote 20 bytes for 1M speed');

@payload = (0x12, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x01, 0, 0, 0, 0);
$checksum = 0;
$checksum += $_ for @payload;
$checksum &= 0xff;
$expected_frame = pack('C C C*', 0xaa, 0x55, @payload, $checksum);
is($written_data, $expected_frame, 'Correct command frame sent for 1M');

# Test 5: close() works
$adapter->close();
is($adapter->{is_open}, 0, 'Adapter is_open is false after close()');
is($adapter->{handle}, undef, 'Adapter handle is undef after close()');

# Test 6: get_fileno() dies if not open
my $closed_adapter = CAN::Adapter::Lawicel->new();
eval { $closed_adapter->get_fileno() };
like($@, qr/Adapter is not open/, 'get_fileno() dies if adapter is not open');

# Test 7: get_fileno() works when open
$adapter->open();
$serial_mock->mock('fileno', sub { return 42; });
my $fileno = $adapter->get_fileno();
is($fileno, 42, 'get_fileno() returns the file descriptor when open');

done_testing();