#!/usr/bin/perl
use strict;
use warnings;
use IPC::Shareable;
use Log::Log4perl qw(:easy);
use FindBin qw($Bin);

Log::Log4perl->easy_init($TRACE);
my $log = Log::Log4perl->get_logger('BMW::CSC::MessageHandler');


my %shared_data;
my $glue = 'bmwcsc'; # A key to identify the shared memory segment
my $shared = tie %shared_data, 'IPC::Shareable', $glue, { create => 1, destroy => 1 };

open(my $child_handle, "-|", "$Bin/spew_test_data.pl") || $log->logdie("$0: can't open data source for reading: $!");
while (my $line = <$child_handle>) {
	chomp $line;
	$log->trace($line);
	#~ $shared->shlock(); # Lock the shared memory
	#~ $shared_data{'timestamp'} = time();
	#~ $shared->shunlock(); # Unlock the shared memory
	};	

# --- Child Exit Handling ---
# The code reaches here only after the while loop exits, which happens
# when the child process terminates and the pipe is closed.
close $child_handle;

my $child_exit_status = $? >> 8;
$log->info("Child process has exited. Exit code: $child_exit_status");

exit 0;