#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use YAML::Tiny 'LoadFile';
use FindBin;
use IPC::Shareable;
use IPC::Semaphore;

# CORRECTED: Import the necessary IPC constants and the ftok function.
use IPC::SysV qw(IPC_CREAT IPC_EXCL ftok);

# --- DIAGNOSTIC LOGGING ---
open(my $diag_fh, '>>', '/tmp/handler_startup.log') or die "Can't open diagnostic log: $!";
print $diag_fh "Message handler TESTER started at: " . localtime() . " (PID: $$)\n";
close($diag_fh);
# --- END DIAGNOSTIC LOGGING ---

Log::Log4perl->easy_init($TRACE);
my $log = get_logger();

# --- Config and Map Creation (Unchanged) ---
my $config_file = "$FindBin::Bin/webapp/config.yml";
my $config = LoadFile($config_file) or die "Could not load YAML";
my %id_info;
foreach my $csc (keys %{ $config->{csc_ids} }) {
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        my $id_data = $config->{csc_ids}->{$csc}->{$id};
        $id_info{$id} = {
            csc      => $csc,
            type     => $id_data->{type},
            cell_map => $id_data->{cell_map} || undef,
        };
    }
}
$log->info("Created reverse lookup map for " . scalar(keys %id_info) . " CAN IDs.");

# --- SEMAPHORE AND SHARED MEMORY SETUP ---
my $glue = 'bmwcsc';
my $sem_key = ftok($0, 1);
IPC::Semaphore->new($sem_key, 1, 0666 | IPC_CREAT)->remove();
my $semaphore = IPC::Semaphore->new($sem_key, 1, 0666 | IPC_CREAT | IPC_EXCL)
    or die "FATAL: Could not create semaphore set: $!";
$semaphore->setval(0, 1);

my $shareable_handle = tie my %can_data_structure, 'IPC::Shareable', $glue, {
    create  => 1,
    destroy => 1,
    mode    => 0666,
} or die "FATAL: Could not create shared memory segment '$glue': $!";
$log->info("Tied memory segment and created semaphore.");

# The child process and the main while loop are completely disabled for this test.
$log->info("Setup complete. Exiting test script.");

# At script exit, ensure the semaphore is removed.
END {
    $semaphore->remove() if $semaphore;
}

exit 0;