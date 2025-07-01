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

# Create a real, but in-memory, filehandle to be blessed for the mock.
# This allows the built-in fileno() to work on our mock object.
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

# --- SEND TESTS ---
subtest 'send method' => sub {
    my $adapter = CAN::Adapter::Lawicel->new();
    $adapter->open();

    $adapter->send(id => '1E0', data => '5ed00000000070d3');

    my $expected_frame = pack('C*', 0xaa, 0xC8, 0xE0, 0x01, 0x5e, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x70, 0xd3, 0x55);
    is($written_data, $expected_frame, 'Correct frame sent for standard ID');
};

# --- READ TESTS ---
subtest 'read_frame method' => sub {
    my $adapter = CAN::Adapter::Lawicel->new();
    $adapter->open();

    # Test 1: Simple complete frame
    $read_buffer = pack('C*', 0xaa, 0xC8, 0x20, 0x01, 0xe4, 0xd0, 0x0e, 0x18, 0x0e, 0x18, 0x0e, 0x18, 0x55);
    my $bytes_read = $adapter->fill_buffer();
    is($bytes_read, 13, 'fill_buffer reads all data');

    my $frame = $adapter->read_frame();
    isa_ok($frame, 'HASH', 'read_frame returns a hashref');
    is($frame->{id}, '120', 'Correct ID parsed');
    is($frame->{dlc}, 8, 'Correct DLC parsed');
    is_deeply($frame->{data}, [0xe4, 0xd0, 0x0e, 0x18, 0x0e, 0x18, 0x0e, 0x18], 'Correct data parsed');

    # Test 2: Garbage at the beginning followed by a good frame
    $read_buffer = pack('C*', 0x11, 0xaa, 0xC1, 0x83, 0x01, 0x3a, 0x55);
    $adapter->fill_buffer();
    my $garbage_frame = $adapter->read_frame();
    is_deeply($garbage_frame, { type => 'error', reason => 'garbage', details => 'Unexpected data from adapter', raw => '11' }, 'Correctly identifies garbage byte');

    my $good_frame = $adapter->read_frame();
    is($good_frame->{id}, '183', 'Correct ID parsed after garbage');
    is($good_frame->{dlc}, 1, 'Correct DLC parsed');
    is_deeply($good_frame->{data}, [0x3a], 'Correct data parsed');

    # Test 3: Corrupted frame (bad end byte) followed by good frame
    $read_buffer = pack('C*', 0xaa, 0xC1, 0x83, 0x01, 0x3a, 0x00, 0xaa, 0xC1, 0x84, 0x01, 0x3b, 0x55);
    $adapter->fill_buffer();
    my $corrupted_frame = $adapter->read_frame();
    is($corrupted_frame->{type}, 'error', 'Corrupted frame returns error type');
    is($corrupted_frame->{reason}, 'corrupted', 'Error reason is "corrupted"');
    is($corrupted_frame->{details}, 'Corrupted data from adapter (bad end byte)', 'Correct details for corrupted frame');
    is($corrupted_frame->{raw}, 'aac183013a00', 'Error contains raw frame data');

    $good_frame = $adapter->read_frame();
    is($good_frame->{id}, '184', 'Good frame parsed after corrupted one');
    is_deeply($good_frame->{data}, [0x3b], 'Correct data parsed from second frame');

    # Test 4: ACK response
    $read_buffer = "\r";
    $adapter->fill_buffer();
    my $ack_frame = $adapter->read_frame();
    is_deeply($ack_frame, { type => 'ack' }, 'Correctly parses ACK');

    # Test 5: NACK response
    $read_buffer = "\a";
    $adapter->fill_buffer();
    my $nack_frame = $adapter->read_frame();
    is_deeply($nack_frame, { type => 'nack' }, 'Correctly parses NACK');

    # Test 6: Unknown frame type
    $read_buffer = pack('C*', 0xaa, 0xB8, 0x01, 0x02, 0x03);
    $adapter->fill_buffer();
    my $unknown_frame = $adapter->read_frame();
    is($unknown_frame->{type}, 'error', 'Unknown frame returns error type');
    is($unknown_frame->{reason}, 'unknown_type', 'Error reason is "unknown_type"');
    is($unknown_frame->{details}, 'Unrecognized frame type from adapter', 'Correct details for unknown type');
    is($unknown_frame->{raw}, 'aab8', 'Error contains raw header');
};

done_testing();