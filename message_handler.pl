#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use YAML::Tiny 'LoadFile';
use Redis;
use JSON::MaybeXS;

# --- Setup ---
Log::Log4perl->easy_init($INFO);
my $log = get_logger();

# --- Pre-flight Device Checks ---
my $device_file = '/dev/ttyUSB0';
unless (-e $device_file) {
    $log->logdie("Device '$device_file' not found. Is CAN adapter connected?");
}
unless (-r $device_file) {
    $log->logdie("Device '$device_file' is not readable. Check file permissions.");
}
$log->info("Device '$device_file' found and is readable.");

# --- Config and Map Creation ---
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

# --- Redis Connection ---
my $redis = Redis->new or $log->logdie("Cannot connect to Redis server");
$log->info("Connected to Redis.");

# --- Reset Statistics Counters ---
$redis->set('bms:stats:total_messages', 0);
$redis->set('bms:stats:corrupted_frames', 0);
$log->info("Redis statistics counters have been reset to zero.");

# --- Child Process Command ---
my $json_coder = JSON::MaybeXS->new(utf8 => 1);
my $message_count = 0;
my $child_process_cmd = "./canusb -d $device_file -s 500000";

$log->info("Starting child process: $child_process_cmd");
open my $child_handle, '-|', $child_process_cmd
    or $log->logdie("Can't run child script '$child_process_cmd': $!");

# --- Main Loop ---
while (my $line = <$child_handle>) {
    $message_count++;
    $redis->incr('bms:stats:total_messages');

    if ($message_count % 10000 == 0) {
        $log->info("[Msg $message_count] Handler is alive, still processing...");
    }

    if ($line =~ /Frame ID: (\S+),\s+Data:\s+(.*)/) {
        my $id = uc($1);
        my $data = $2;
        chomp $data;

        if (my $info = $id_info{$id}) {
            my ($csc, $type) = ($info->{csc}, $info->{type});
            my $update_payload;
            
            $redis->set("bms:heartbeat:$csc", time());

            if ($type eq 'voltage' && $info->{cell_map}) {
                my @bytes = split /\s+/, $data;
                my %voltages;
                foreach my $start_byte (keys %{$info->{cell_map}}) {
                    my $cell_num = $info->{cell_map}->{$start_byte};
                    if (defined $bytes[$start_byte] && defined $bytes[$start_byte + 1]) {
                        my $voltage = sprintf("%.2f", convert_bytes_to_voltage($bytes[$start_byte], $bytes[$start_byte + 1]));
                        $voltages{$cell_num} = $voltage;
                        $redis->hset("bms:csc:$csc", $cell_num, $voltage);
                    }
                }
                $update_payload = { csc => $csc, id => $id, type => 'voltage', voltages => \%voltages };
                $redis->publish('bms:updates', $json_coder->encode($update_payload));
                $log->trace("[Msg $message_count] Processed voltages for CSC $csc, ID $id");

            } elsif ($type eq 'temperature' && $info->{sensor_map}) {
                my @bytes = split /\s+/, $data;
                my %sensor_temps;
                foreach my $byte_index (keys %{$info->{sensor_map}}) {
                    my $sensor_num = $info->{sensor_map}->{$byte_index};
                     if (defined $bytes[$byte_index]) {
                        my $temp = convert_byte_to_temp($bytes[$byte_index]);
                        $sensor_temps{$sensor_num} = $temp;
                        $redis->hset("bms:csc_temps:$csc", $sensor_num, $temp);
                    }
                }
                $update_payload = { csc => $csc, id => $id, type => 'temperature', temps => \%sensor_temps };
                $redis->publish('bms:updates', $json_coder->encode($update_payload));
                $log->trace("[Msg $message_count] Processed temperatures for CSC $csc, ID $id");

            } else { # 'unknown' type
                $redis->hset("bms:csc_raw:$csc", $id, $data);
                $update_payload = { csc => $csc, id => $id, type => 'unknown', data => $data };
                $redis->publish('bms:updates', $json_coder->encode($update_payload));
                $log->trace("[Msg $message_count] Stored raw data for CSC $csc, ID $id, Type $type");
            }
        } else {
            $log->debug("[Msg $message_count] Ignored unknown CAN ID: $id");
        }
    }
    elsif ($line =~ /frame_recv\(\) failed: Checksum incorrect/) {
        $redis->incr('bms:stats:corrupted_frames');
        $log->warn("[Msg $message_count] Detected corrupted frame.");
    }
    elsif ($line =~ /Unknown:/) {
        $log->trace("[Msg $message_count] Ignoring incomplete data packet.");
    }
    else {
        chomp $line;
        $log->warn("[Msg $message_count] Could not parse unhandled line: '$line'");
    }
}

close $child_handle;
$log->info("Child process exited. Message handler stopping.");

# --- Subroutines ---
sub convert_bytes_to_voltage {
    my ($byte1_hex, $byte2_hex) = @_;
    my $hex_string = $byte1_hex . $byte2_hex;
    my $decimal_value = hex($hex_string);
    return $decimal_value / 1000.0;
}

sub convert_byte_to_temp {
    my ($byte_hex) = @_;
    return hex($byte_hex) - 40;
}
