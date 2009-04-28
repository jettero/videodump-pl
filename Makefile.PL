# vi:set syntax=perl:

require 5.006001;

use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    'NAME'         => 'videodump-pl',
    'VERSION_FROM' => 'videodump.pl',
    'PREREQ_PM'    => { 
        'Pod::Usage'     => 0,
        'File::Spec'     => 0,
        'File::Copy'     => 0,
        'File::Basename' => 0,
        'Time::HiRes'    => 0,
        'Getopt::Long'   => 0,
    },

    ($ExtUtils::MakeMaker::VERSION ge '6.48'? 
        (MIN_PERL_VERSION => 5.006001,
            META_MERGE => {
                keywords => [qw(mythbuntu hauppage)],
                resources=> {
                    repository => 'http://github.com/jettero/videodump-p',
                },
            },

        LICENSE	=> 'GPL',
    ) : ()),
);
