#!/usr/bin/perl

# videodump for Hauppauge HD PVR 1212 by David & Paul

use strict;
use warnings;

use Fcntl qw(:flock);
use Getopt::Long;
use POSIX qw(setsid strftime);
use File::Spec;
use File::Basename;
use IPC::Open3;
use File::Copy;
use Cwd;
use Time::HiRes qw(sleep);
use Pod::Usage;

our $VERSION = "1.52";

my $lockfile       = "/tmp/.vd-pl.lock";
my $channel        = "";
my $description    = "imported by HD PVR videodump & myth.rebuilddatabase.pl";
my $group          = "mythtv";
my $myth_import;
my $name           = "manual_record";
my $output_path    = '/var/lib/mythtv/videos/';
my $mysql_password;
my $remote         = "dish";
my $subtitle       = "recorded by HD PVR videodump";
my $show_length    = 1800;
my $buffer_time    = 7;
my $video_device   = '/dev/video0';
my $file_ext       = "mp4";
my $skip_irsend;
my $become_daemon;

Getopt::Long::Configure("bundling"); # make switches case sensitive (and turn on bundling)
# getopts("HhIfb:c:d:g:L:m:n:o:p:r:s:t:v:x:", \%o) or pod2usage();
GetOptions(
    "lockfile|L=s"       => \$lockfile, 
    "channel|c=s"        => \$channel, 
    "description|d=s"    => \$description,
    "group|g=s"          => \$group,
    "myth-import|m=i"    => sub { $myth_import = $_[1]; die "--myth-import(-m) can only be set to 1 or 2" },
    "name|n=s"           => \$name,
    "output-path|o=s"    => \$output_path,
    "mysql-password|p=s" => \$mysql_password,
    "remote|r=s"         => \$remote,
    "subtitle|s=s"       => \$subtitle,
    "show-length|t=i"    => sub { $show_length = $_[1]*60 }, # convert minutes to seconds
    "buffer-time|b=i"    => \$buffer_time,
    "video-device|v=s"   => \$video_device,
    "file-ext|x=s"       => \$file_ext,
    "skip-irsend|I"      => \$skip_irsend,
    "help|H"             => sub { pod2usage(-verbose=>1) },
    "h"                  => sub { pod2usage() },
    "background|f"       => \$become_daemon,

) or pod2usage();

if ($show_length - $buffer_time <= 0 ) {
    die "Come on, you need to record for longer than that!: $!"; # $show_length - $buffer_time must be greater than zero seconds
}

if ($mysql_password and not defined $myth_import) {
    die "If you supply a password for mysql, you need to tell me how to import with the -m switch!";
}

if (defined $myth_import and not defined $mysql_password) {
    die "If you want me to import, you need to supply your mysql password!";
}

umask 0007 if $group; # umask 0007 leaves group write bit on, good when using group chown() mode

# NOTE: we're being paranoid about input filenames, it's a good habit.

$output_path  = File::Spec->rel2abs($output_path);
$output_path  = getcwd() unless -d $output_path and -w _;
$video_device = File::Spec->rel2abs($video_device);

my $start_time      = strftime('%y-%m-%d %H:%M:%S', localtime); # need colons for future import into mythtv database, not file name.
my $start_time_name = strftime('%y-%m-%d %l.%M%P', localtime);
my $commflag_name   = strftime('%y%m%d%H%M%S', localtime); # needed so we can commflag our recording, myth.rebuilddatabase.pl renames the file to this format after it imports it

my $output_basename = basename("$name $start_time_name $channel.$file_ext"); # filename includes date, time and channel, colons can cause issues ouside of linux
my $output_filename = File::Spec->rel2abs( File::Spec->catfile($output_path, $output_basename) );

if( $become_daemon ) {
    # fork/daemonize -- copied from http://www.webreference.com/perl/tutorial/9/3.html
    defined(my $pid = fork) or die "can't fork: $!";
    exit if $pid;
    setsid() or die "can't create a new session: $!";
}



#lock the source and make sure it isn't currently being used
open my $lockfile_fh, ">", $lockfile or die "error opening lockfile \"$lockfile\": $!";
while( not flock $lockfile_fh, (LOCK_EX|LOCK_NB) ) {
    warn "couldn't lock lockfile \"$lockfile,\" waiting for a turn...\n";
    sleep 5;
}

# now lets change the channel, now compatable with up to 4 digits
unless( $skip_irsend ) {
    systemx ("irsend", "SEND_ONCE", $remote, "SELECT"); # needs to be outside of sub change_channel
    sleep 1; # give it a second to wake up before sending the digits

    sub change_channel {
        my($channel_digit) = @_;

    #some set top boxes need to be woken up
        systemx ("irsend", "SEND_ONCE", $remote, $channel_digit);
        sleep 0.2; # channel change speed, 1 sec is too long, some boxes may timeout
    }

    sleep 1;

    if (length($channel) > 3) {
        change_channel(substr($channel, 0, 1));
        change_channel(substr($channel, 1, 1));
        change_channel(substr($channel, 2, 1));
        change_channel(substr($channel, 3, 1));

    } elsif (length($channel) > 2) {
        change_channel(substr($channel, 0, 1));
        change_channel(substr($channel, 1, 1));
        change_channel(substr($channel, 2, 1));

    } elsif (length($channel) > 1) {
        change_channel(substr($channel, 0, 1));
        change_channel(substr($channel, 1, 1));

    } else {
        change_channel(substr($channel, 0, 1));
    }

    # may or may not need to send the ENTER command after the channel numbers are sent
    # remove comment from next line if necessary, may need to try OK or ENTER instead of SELECT.
    #systemx ("irsend SEND_ONCE $remote SELECT");
}

#systemx(echo,$show_length);
#systemx(echo,$buffer_time);
#systemx(echo,$show_length-$buffer_time);
#die;

#capture native AVS format h264 AAC
ffmpegx(

    "-y",                                     # it's ok to overwrite the output file
    "-i"      => $video_device,               # the input device
    "-vcodec" => "copy",                      # copy the video codec without transcoding, probably asking to much to call a specific encoder for real time capture
    "-acodec" => "copy",                      # what do you know, AAC is playable by default by the internal myth player
    "-t"      => $show_length-$buffer_time,   # -t record for this many seconds ... $o{t} was multiplied by 60 and is in minutes....minus buffer/recovery time

$output_filename);

close $lockfile_fh; # release the video device for the next recording process.

# now let's import it into the mythtv database
# XXX: I reordered this to make a smarter flow, and altered the -m docs to match
if( defined $myth_import ) {
    if ($myth_import == 2) {
        # -m 2 means we transcode to native format
        my $transcode_basename = $output_basename;
           $transcode_basename =~ s/\.\Q$file_ext\E$/.mpg/;
        my $transcode_filename = "$output_path/$transcode_basename";

        unless( -f $transcode_filename ) {
            ffmpegx(

                 "-i" => $output_filename,
                 "-acodec" => "ac3", "-ab" => "192k",
                 "-vcodec" => "mpeg2video", "-b" => "10.0M", "-cmp" => 2, "-subcmp" => 2,
                 "-mbd" => 2, "-trellis" => 1, $transcode_filename);

            # probably need a command here to delete the original if the conversion was sucessfull???
            # if, then, type of command, but not sure how to tell if it converted sucessfully

            # use these from here down
            $output_basename = $transcode_basename;
            $output_filename = $transcode_filename;
            $file_ext = "mpg";

            # lets optimize the database to be sure it doesn't have any errors
            # this may not be the best way to do it
            # first optimize database, the script is going to need 755 perms or something similar
            # NOTE: script won't need 755 if you fork and use $^X
            # Originally located at /usr/share/doc/mythtv-backend/contrib/
            # You will need to untar and place in your path.
            #systemx($^X,"optimize_mythdb.pl");

        } else {
            warn "WARNING: skipping transcode, already in mpeg format?\n";
        }

    }

    # -m 1 and -m 2 both need a rebuilddatabase call

    # XXX: myth.rebuilddatabase.pl must be unziped and installed with correct perms somewhere in the path
    # mythbuntu distributes it in gz format to this location, however, your distro may be different
    # /usr/share/doc/mythtv-backend/contrib/myth.rebuilddatabase.pl.gz

    # to be sure the recorded file plays well, lets do a (non-reencoding) transcode of the file
    systemx('mythtranscode', 
        "--mpeg2", "--buildindex", "--allkeys", "--showprogress", "--infile", 
        "$output_path/$output_basename");

    # import into MythTV mysql database so it is listed with all your other recorded shows
    systemx("myth.rebuilddatabase.pl",
        "--dbhost", "localhost", "--pass", $mysql_password, "--dir", $output_path, "--file", $output_basename, 
        "--answer", "y", "--answer", $channel, "--answer", $name, "--answer", $subtitle, 
        "--answer", $description, "--answer", $start_time, "--answer", "Default", 
        "--answer", ($show_length)/60, "--answer", "y");

    # to be sure the recorded file plays well, lets do a (non-reencoding) transcode of the file
    # XXX: we do this after import in any import mode?  is that right?  Should it go before the import?
    # The import changes the file name, so if transcode is done after the import, this command is slightly different
    # Not sure if it should be before or after.
#    systemx('mythtranscode', 
#        "--mpeg2", "--buildindex", "--allkeys", "--showprogress", "--infile", 
#        "$output_path/$channel\_$commflag_name.$file_ext");

    # Now let's flag the commercials
    # It doesn't look like "real-time flagging" can be done.
    # This process takes longer than normal with the files created by the HDPVR.  This is something that should be figgured out at some point.
    systemx("mythcommflag","-f","$output_path/$channel\_$commflag_name.$file_ext");
    systemx('echo',"$output_basename");
    systemx('echo',"$output_path");
    systemx('echo',"$output_path/$channel\_$commflag_name.$file_ext");
}

# some database cleanup only if there are files that exist without entries or entries that exist without files
#systemx("myth.find_orphans.pl", "--dodbdelete", "--dodelete", "--pass", $mysql_password);

use Carp;
sub systemx {
    # stolen from IPC::System::Simple (partially)
    my $command = shift;
    CORE::system { $command } $command, @_;

    croak "child process failed to execute" if $? == -1;
    croak "child process returned error status" if $? != 0;
}

sub ffmpegx {
    # needed in more than one place

    my @cmd = @_;
    my $file = $cmd[-1];

    local $SIG{PIPE} = sub { die "execution failure while forking ffmpeg!\n"; };

    my $logfile = "/tmp/$name.log";
    open my $log, ">>", $logfile or die $!;
    print $log localtime() . "\n-----started cmd[@cmd]\n";

    my ($output_filehandle, $stdout, $stderr);
    my $pid = open3($output_filehandle, $stdout, $stderr, ffmpeg=>@cmd);
    close $output_filehandle;

    print $log localtime() . "(0): $_" while <$stdout>;

    # NOTE: from manpage, "If CHLD_ERR is false, or the same file descriptor as
    # CHLD_OUT, then STDOUT and STDERR of the child are on the same
    # filehandle." -- solves a concurrency problem anyway.  Awesome.
    # ### print $log localtime() . "(1): $_" while <$stderr>;

    waitpid($pid, 0); # ignore the return value... it probably returned.  (may also cause problems later)
                      # ffmpeg exit status is returned in $?

    if( $? ) {
        move($file, "$file-err"); # if this fails, it doesn't really matter
        warn "\nffmpeg error, see tmp error log dump ($logfile) for further information, video moved to: $file-err\n";
        print "\nThe last 15 lines of $logfile:\n";
        exec(tail => '-n', 15, $logfile) or die "huh... $!";
    }

    if( $group ) {
        if( my $gid = getgrnam($group) ) {
            chown $<, $gid, $file or warn "couldn't change group of output file: $!";

        } else {
            warn "couldn't locate group \"$group\"\n";
        }
    }

    # When everythign goes ok, we should probably remove the ffmpeg logdump.
    close $log; unlink $logfile;
}

__END__
# misc comment

=head1 NAME

Videodump-PL - A simple script for recording from generic video stream devices in MythTV

=head1 DESCRIPTION

Until myth gets support for a certain device under v0.22, at least one of the
authors of this script were dead in the water.  This script will likely work
with any hardware (/dev/video*) type device that dumps a video/audio stream.

=head1 SYNOPSIS

 videodump.pl
    -h help
    --help (-H) full help

    --buffer-time  (-b) buffer/recovery time
    --channel      (-c) channel
    --description  (-d) show description
    --background   (-f) fork/daemonize
    --group        (-g) group
    --lockfile     (-L) lockfile
    --myth-import  (-m) mythtv mysql import option (requires -p)
    --name         (-n) show name
    --output-path  (-o) output path
    --mysql-passwd (-p) mysql password (may require -o and/or -m)
    --remote       (-r) remote device
    --subtitle     (-s) subtitle description
    --show-length  (-t) length in minutes (default: 30 minutes)
    --video-device (-v) video device (default: /dev/video0)
    --file-ext     (-x) file extension (default: ts), alters ffmpeg behavior
    --skip-irsend  (-I) skip irsend commands

=head1 OPTIONS

=over

=item B<-b> B<--buffer-time>

buffer/recovery time in seconds needed between recordings to reset for next
show default 1 second per 1 minute of recording time

=item B<-c> B<--channel>

channel, (default is nothing, just record whatever is on at the time)

=item B<-d> B<--description>

description detail (default imported by HD PVR)

=item B<-f> B<--background>

fork/daemonize (fork/detatch and run in background)

=item B<-g> B<--group>

group to chgroup files to after running ffmpeg (default: mythtv if it exists,
'0' to disable)

=item B<-L> B<--lockfile>

lockfile location (default: /tmp/.vd-pl.lock)

=item B<-m> B<--mysql-import>

mysql import type 1 and 2 requires -p

When --mysql-import(-m) isn't specified, this script simply does a raw dump to
output folder (--output-path/-o).  Recording will be available for manual play
as soon as recording starts, will NOT show up in mythtv mysql "recorded shows"
list, best dumped to default MythVideo Gallery folder.

=over

=item B<1>

The output folder (output-path/-o) must be where mythtv recordings are stored
by default.  Shows will be imported into mysql imediately after they are done
recording in raw format.  Requires mysql password (--mysql-passwd/-p) switch!

=item B<2>

Same as 1, but shows will be converted to mythtv native mpeg2 format with
commercial flagging points.  They will also show up in the recorded shows list
after mpeg2 conversion (time will vary based on CPU).  Requires mysql password
(--mysql-passwd/-p) switch.

=back

=item B<-n> B<--name>

name of file, also used as title (default: manual_record)

=item B<-o> B<--output-path>

output path where you want shows to be placed needs / at end (default
/var/lib/mythtv/videos/)

=item B<-p> B<--mysql-passwd>

mysql password, default is blank.  If you supply a password, will attempt to
import into MythTV mysql!  Found in Frontend -> Utilities/Setup->Setup->General
You need supply -o, which needs to be the path to your MythTV recorded shows folder.
You should use -m (1 or 2).  If -m switch is not used, (-m 1) is assumed.

=item B<-r> B<--remote>

remote device to be controled by IR transmitter, change in MythTV Control
Centre, look at /etc/lircd.conf for the chosen device blaster file that
contains the name to use here (default dish)

=item B<-s> B<--subtitle>

subtitle description (default: recorded by HD PVR)

=item B<-t> B<--show-length>

The length of a show in minutes (default: 30 minutes)

=item B<-v> B<--video-device>

The device or video file you wish to record from or process (default: /dev/video0)

=item B<-x> B<--file-ext>

The file extension to be passed to ffmpeg.  The extension alters the behavior of
ffmpeg by changing the container format of the output!

The myth internal player plays the default (mp4) well. ts containers seem to
play well also.  mp4 converts to better mpeg2 output.  External players play mp4
well, but possibly not ts.

=item B<-I> B<--skip-irsend>

Skip all irsend commands.  These commands are intended to change channels and
things, which may not be applicable or useful to all users.

=back

=head1 COPYRIGHT

Copyright 2009 -- David Stoll and Paul Miller

GPL

=head1 REPORTING BUGS

Please use the issue tracker at github:

C<http://github.com/jettero/videodump-pl/issues>

=head1 REPOSITORY

C<http://github.com/jettero/videodump-pl>

=head1 SEE ALSO

perl(1), ffmpeg(1)

=cut
