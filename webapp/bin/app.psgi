#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";


# use this block if you don't need middleware, and only have a single target Dancer app to run here
use BMW::CSC::Diagnoser;

BMW::CSC::Diagnoser->to_app;

=begin comment
# use this block if you want to include middleware such as Plack::Middleware::Deflater

use BMW::CSC::Diagnoser;
use Plack::Builder;

builder {
    enable 'Deflater';
    BMW::CSC::Diagnoser->to_app;
}

=end comment

=cut

=begin comment
# use this block if you want to mount several applications on different path

use BMW::CSC::Diagnoser;
use BMW::CSC::Diagnoser_admin;

use Plack::Builder;

builder {
    mount '/'      => BMW::CSC::Diagnoser->to_app;
    mount '/admin'      => BMW::CSC::Diagnoser_admin->to_app;
}

=end comment

=cut

