#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use YAML::Tiny 'LoadFile';
use Redis;
use JSON::MaybeXS;
use IPC::SysV qw(ftok);

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
        $log->warn("Device '$device_file' not found or not readable. Awaiting connection...");
        while (1) {
            sleep(5);
            last if (-e $device_file && -r $device_file);
        }
    }
    $log->info("Device '$device_file' detected. Starting CAN process.");

    # 2. Message Processing Phase
    my $child_process_cmd = "./canusb -d $device_file -s 500000";
    open my $child_handle, '-|', $child_process_cmd
        or $log->logdie("Failed to start child process '$child_process_cmd': $!");
    
    $log->info("Reading from child process...");
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
                my $now = time();
                my $update_payload;
                
                $redis->set("bms:heartbeat:$csc", $now);
                
                my $csc_freq_key = "bms:msg_times:$csc";
                $redis->zremrangebyscore($csc_freq_key, '-inf', $now - 3);
                $redis->zadd($csc_freq_key, $now, "$now:$message_count");
                $redis->expire($csc_freq_key, 10);

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

                } elsif ($type eq 'total_voltage') {
                    my @bytes = split /\s+/, $data;
                    if (defined $bytes[6] && defined $bytes[7]) {
                        # CORRECTED: Re-introduced the 2x scaling factor
                        my $val = (hex($bytes[6] . $bytes[7])) * 2;
                        $redis->set("bms:csc_total_v:$csc", $val);
                        $update_payload = { csc => $csc, id => $id, type => 'total_voltage', value => $val };
                        $redis->publish('bms:updates', $json_coder->encode($update_payload));
                        $log->trace("[Msg $message_count] Processed total voltage for CSC $csc, ID $id");
                    }
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
    $log->warn("Child process terminated, possibly due to device disconnect. Rescanning...");
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
