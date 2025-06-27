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
    },
    PREREQ_PM => {
        'Device::SerialPort' => '1.04',
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'CAN-Adapter-Lawicel-*' },
