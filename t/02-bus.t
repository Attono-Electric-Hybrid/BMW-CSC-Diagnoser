use strict;
use warnings;
use Test::More;

# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/../lib";

use CAN::Adapter::Lawicel;
use Test::MockModule;

my $written_data;
my $read_buffer = '';

# --- Mock Linux::Termios2 ---
# The module now uses raw filehandles and POSIX calls. We mock the entire 'open'
# method since its low-level details are tested by the hardware tests. For the
# other methods, we mock the internal I/O wrappers.
my $adapter_mock = Test::MockModule->new('CAN::Adapter::Lawicel');

# 1. Mock 'open' to just set the state and provide an in-memory filehandle.
my $in_memory_buffer;
$adapter_mock->mock('open', sub {
    my $self = shift;
    $self->{is_open} = 1;
    open my $fh, '+>', \$in_memory_buffer;
    $self->{handle} = $fh;
    return 1;
});

# 2. Mock the internal I/O methods to use our buffers.
$adapter_mock->mock(
    'send_raw' => sub {
        my $self = shift;
        my ($data) = @_;
        $written_data = $data;
        # If this is a settings command, simulate the adapter sending back an ACK
        if ($data =~ /^\xaa\x55\x12/) {
            $read_buffer .= "\r";
        }
        elsif ($data eq "C\r") {
            $read_buffer .= "\r";
        }
        elsif ($data eq "V\r") {
            $read_buffer = "V9876\r";
        }
        return 1;
    },
    'fill_buffer' => sub {
        my $self = shift;
        return 0 unless length $read_buffer;
        $self->{_in_buffer} .= $read_buffer;
        my $len = length $read_buffer;
        $read_buffer = '';
        return $len;
    },
    'purge_rx' => sub { $read_buffer = ''; 1; },
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