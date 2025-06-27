use strict;
use warnings;
use Test::More;

# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Test 1: Module loads
use_ok('CAN::Adapter::Lawicel');

# Test 2: Can create a new object with defaults
my $adapter = CAN::Adapter::Lawicel->new;
isa_ok($adapter, 'CAN::Adapter::Lawicel', 'new() returns a blessed object');
is($adapter->{device}, '/dev/ttyUSB0', 'new() sets default device');
is($adapter->{baudrate}, 2000000, 'new() sets default baudrate');
is($adapter->{handle}, undef, 'handle is initially undef');
is($adapter->{is_open}, 0, 'is_open is initially false');

# Test 3: Can override device and baudrate
my $test_device = '/dev/ttyS0';
my $test_baud = 9600;
$adapter = CAN::Adapter::Lawicel->new(device => $test_device, baudrate => $test_baud);
is($adapter->{device}, $test_device, 'new() overrides device');
is($adapter->{baudrate}, $test_baud, 'new() overrides baudrate');

done_testing();