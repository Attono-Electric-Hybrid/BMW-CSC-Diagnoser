#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use YAML::Tiny 'LoadFile';
use Redis;
use JSON::MaybeXS;
use IPC::SysV qw(ftok);
use IO::Select;

# --- Setup ---
Log::Log4perl->easy_init($INFO);
my $log = get_logger();

my $device_file = '/dev/ttyUSB0';
my $config_file = './webapp/config.yml';

my $config = LoadFile($config_file)
    or $log->logdie("Could not load YAML from '$config_file'");

my %id_info;
foreach my $csc (keys %{ $config->{csc_ids} }) {
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        my $id_data = $config->{csc_ids}->{$csc}->{$id};
        $id_info{$id} = {
            csc        => $csc,
            type       => $id_data->{type},
            cell_map   => $id_data->{cell_map}   || undef,
            sensor_map => $id_data->{sensor_map} || undef,
        };
    }
}
$log->info("Created reverse lookup map for " . scalar(keys %id_info) . " CAN IDs.");

my $redis = Redis->new or $log->logdie("Cannot connect to Redis server");
$log->info("Connected to Redis.");

$redis->set('bms:stats:total_messages', 0);
$redis->set('bms:stats:corrupted_frames', 0);
$log->info("Redis statistics counters reset.");

my $json_coder = JSON::MaybeXS->new(utf8 => 1);
my $message_count = 0;

# --- Main Control Loop ---
while (1) {
    
    # 1. Device Discovery Phase
    unless (-e $device_file && -r $device_file) {
        $log->warn("Awaiting connection of device '$device_file'...");
        while (1) {
            sleep(5);
            last if (-e $device_file && -r $device_file);
        }
    }
    $log->info("Device '$device_file' detected. Starting CAN process.");

    # 2. Message Processing Phase
    my $child_process_cmd = "./canusb -d $device_file -s 500000 2>&1";
    
    my $pid = open my $child_handle, '-|', $child_process_cmd
        or $log->logdie("Failed to start child process '$child_process_cmd': $!");
    
    my $io_select = IO::Select->new($child_handle);

    $log->info("Reading from child process (PID: $pid)...");
    
    # New timed-read loop
    while (my @ready = $io_select->can_read(5.0)) { # 5 second timeout
        if (@ready) {
            my $line = <$child_handle>;
            
            unless (defined $line) {
                # End of File - child exited cleanly.
                $log->info("Child process pipe closed cleanly.");
                last; # Exit this read loop
            }

            $message_count++;
            $redis->incr('bms:stats:total_messages');
            
            # ... (The entire if/elsif/else block for parsing $line is unchanged) ...

        } else {
            # Timeout - can_read returned an empty list
            $log->warn("Child process (PID: $pid) is unresponsive. Terminating it.");
            kill 'TERM', $pid;
            last; # Exit this read loop
        }
    }

    # This point is reached if the pipe closes or the child is killed.
    close $child_handle;
    $log->warn("Stopped reading from child. Will re-scan for device.");
    sleep(1);
}

# --- Subroutines ---
sub convert_bytes_to_voltage {
    my ($byte1_hex, $byte2_hex) = @_;
    return hex($byte1_hex . $byte2_hex) / 1000.0;
}

sub convert_byte_to_temp {
    my ($byte_hex) = @_;
    return hex($byte_hex) - 40;
}
