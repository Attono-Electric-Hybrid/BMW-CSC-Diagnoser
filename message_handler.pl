#!/usr/bin/perl
use strict;
use warnings;
use Redis;
use Log::Log4perl qw(:easy);
use FindBin qw($Bin);
use YAML::Tiny;
use JSON::MaybeXS;

Log::Log4perl->easy_init($INFO);
my $log = Log::Log4perl->get_logger('BMW::CSC::MessageHandler');

# --- Load CSC ID Configuration from YAML ---
my $config_file = "$Bin/webapp/config.yml"; 
my $config;

eval {
    my $yaml_docs = YAML::Tiny->read($config_file);
    # The parsed data is the first document in the file.
    $config = $yaml_docs->[0];
};
if ($@ || !defined($config)) {
    $log->logdie("FATAL: Could not read or parse YAML config file '$config_file': " . ($@ || 'File is empty'));
}

$log->info("Successfully loaded CSC ID configuration from $config_file");

# --- In-memory ID info map for fast lookups ---
my %id_info;
foreach my $csc (keys %{ $config->{csc_ids} }) {
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        my $id_data = $config->{csc_ids}->{$csc}->{$id};
        $id_info{$id} = {
            csc      => $csc,
            type     => $id_data->{type},
            # Store the cell_map if it exists for this ID
            cell_map => $id_data->{cell_map} || undef,
        };
    }
}
$log->info("Created reverse lookup map for " . scalar(keys %id_info) . " CAN IDs.");

# Connect to the Redis server (assumes default localhost:6379)
my $redis = Redis->new or $log->logdie("Cannot connect to Redis server");
$log->info("Connected to Redis.");

my $json_coder = JSON::MaybeXS->new(utf8 => 1);
my $message_count = 0;
my $child_script_cmd = "perl $FindBin::Bin/data_streamer.pl";
open my $child_handle, '-|', $child_script_cmd or die "Can't run child script: $!";

# --- Main Loop ---
while (my $line = <$child_handle>) {
    $message_count++;
    if ($line =~ /Frame ID: (\S+),\s+Data:\s+(.*)/) {
        my $id = uc($1);
        my $data = $2;
        chomp $data;

        if (my $info = $id_info{$id}) {
            my ($csc, $type) = ($info->{csc}, $info->{type});
            my $update_payload;

            if ($type eq 'voltage' && $info->{cell_map}) {
                my @bytes = split /\s+/, $data;
                my %voltages;
                foreach my $start_byte (keys %{$info->{cell_map}}) {
                    my $cell_num = $info->{cell_map}->{$start_byte};
                    if (defined $bytes[$start_byte] && defined $bytes[$start_byte + 1]) {
                        my $voltage = sprintf("%.2f", convert_bytes_to_voltage($bytes[$start_byte], $bytes[$start_byte + 1]));
                        $voltages{$cell_num} = $voltage;
                        # Set the voltage for the specific cell in the CSC's hash
                        $redis->hset("bms:csc:$csc", $cell_num, $voltage);
                    }
                }
                $update_payload = { csc => $csc, id => $id, type => 'voltage', voltages => \%voltages };
            } else {
                # For unknown types, just store the raw data
                $redis->hset("bms:csc_raw:$csc", $id, $data);
                $update_payload = { csc => $csc, id => $id, type => 'unknown', data => $data };
            }
            
            # Publish a notification of the update for the logger
            $redis->publish('bms:updates', $json_coder->encode($update_payload));
            
            # Update the global heartbeat
            $redis->set('bms:heartbeat', time());
            
            $log->trace("[Msg $message_count] Wrote ID $id to Redis.");
        }
    }
}

# --- Child Exit Handling ---
# The code reaches here only after the while loop exits, which happens
# when the child process terminates and the pipe is closed.
close $child_handle;

my $child_exit_status = $? >> 8;
$log->info("Child process has exited. Exit code: $child_exit_status");

sub convert_bytes_to_voltage {
    my ($byte1_hex, $byte2_hex) = @_;

    # 1. Convert each byte from hex to a decimal number.
    my $dec1 = hex($byte1_hex);
    my $dec2 = hex($byte2_hex);

    # 2. Concatenate the numbers as strings (second number first).
    my $concatenated = $dec2 . $dec1;

    # 3. Conditional: If > 9999, place a decimal point after the 4th digit.
    if ($concatenated > 9999) {
        substr($concatenated, 4, 0, '.');
    }

    # 4. Divide by 1000.
    my $divided = $concatenated / 1000;

    # 5. Add 2.
    my $final_voltage = $divided + 2;

    return $final_voltage;
}

exit 0;