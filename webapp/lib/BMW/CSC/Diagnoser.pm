package BMW::CSC::Diagnoser;
use Dancer2;
use Log::Log4perl qw(:easy);
use AnyEvent;

Log::Log4perl->easy_init($TRACE);

our $VERSION = '0.1';

my $log = Log::Log4perl->get_logger('BMW::CSC::Diagnoser');

my $wait_for_input = AnyEvent->io (
   fh   => \*STDIN, # which file handle to check
   poll => "r",     # which event to wait for ("r"ead data)
   cb   => sub {    # what callback to execute
    my $data = <STDIN>; # read it
	$log->debug($data);
   }
);

get '/' => sub {
    template 'index' => { 'title' => 'BMW::CSC::Diagnoser' };
};



true;
