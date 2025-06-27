use strict;
use warnings;
use Test::More;

# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Test 1: Module loads
use_ok('CAN::Adapter::Lawicel');

# Test 2: Can create a new object
my $adapter = CAN::Adapter::Lawicel->new;
isa_ok($adapter, 'CAN::Adapter::Lawicel', 'new() returns a blessed object');

# Test 3: Default device is correct
is($adapter->{device}, '/dev/ttyUSB0', 'new() sets default device');

# Test 4: Can override device
my $test_device = '/dev/null';
$adapter = CAN::Adapter::Lawicel->new(device => $test_device);
is($adapter->{device}, $test_device, 'new() overrides device');

done_testing();