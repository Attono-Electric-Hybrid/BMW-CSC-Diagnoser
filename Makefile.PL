use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'CAN::Adapter::Lawicel',
    AUTHOR           => q{Gemini Code Assist},
    VERSION_FROM     => 'lib/CAN/Adapter/Lawicel.pm',
    ABSTRACT_FROM    => 'lib/CAN/Adapter/Lawicel.pm',
    LICENSE          => 'perl',
    PL_FILES         => {},
    MIN_PERL_VERSION => '5.006',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    BUILD_REQUIRES => {
        'Test::More' => '0',
        'Test::MockModule' => '0.177',
        'Test::Exception' => '0',
        'ExtUtils::CChecker' => '0',
    },
    PREREQ_PM => {
        'Device::SerialPort' => '1.04',
        'Linux::Termios2'    => '0', # For custom baud rate support
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'CAN-Adapter-Lawicel-*' },
);