#!/usr/bin/perl

# videodump for Hauppauge HD PVR 1212 by David & Paul

use strict;
use warnings;

use Fcntl qw(:flock);
use Getopt::Std;
use POSIX qw(setsid strftime);
use File::Spec;
use File::Basename;
use IPC::Open3;
use File::Copy;
use Cwd;
use Time::HiRes qw(sleep);
use Pod::Usage;

our $VERSION = "1.49";

my %o;

getopts("Hhfb:c:d:g:L:m:n:o:p:r:s:t:v:x:", \%o) or pod2usage();
pod2usage() if $o{h};
pod2usage(-verbose=>1) if $o{H};

my $lockfile       = $o{L} || "/tmp/.vd-pl.lock";
my $channel        = $o{c} || "";
my $description    = $o{d} || "imported by HD PVR videodump & myth.rebuilddatabase.pl";
my $group          = $o{g} || "mythtv";
my $myth_import    = $o{m}; # allows for different levels of importing into mythtv, see help file for details
my $name           = $o{n} || "manual_record";
my $output_path    = $o{o} || '/var/lib/mythtv/videos/'; # this should be your default gallery folder, you may want to change this to your MythTV recorded shows folder if you use -p
my $mysql_password = $o{p}; # xfPbTC5xgx
my $remote         = $o{r} || "dish";
my $subtitle       = $o{s} || "recorded by HD PVR videodump";
my $show_length    = ($o{t} || 30)*60; # convert time to minutes
my $buffer_time    = $o{b} || 7; # subtract a few seconds from show length to give unit time to recover for next recording if one immediately follows
my $video_device   = $o{v} || '/dev/video0';
my $file_ext       = $o{x} || "ts"; # good idea to leave it default, internal player plays the default well, if you want to play with some other player, then consider a change


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

if( $o{f} ) {
    # fork/daemonize -- copied from http://www.webreference.com/perl/tutorial/9/3.html
    defined(my $pid = fork) or die "can't fork: $!";
    exit if $pid;
    setsid() or die "can't create a new session: $!";

    close STDOUT; # NOTE: normally a daemonized process will do this...
    close STDIN;  # the reason I added it today was that many of the ffmpeg examples
                  # use ffmpeg -b -l -a -h < /dev/null & when they background things.
}



#lock the source and make sure it isn't currently being used
open my $lockfile_fh, ">", $lockfile or die "error opening lockfile \"$lockfile\": $!";
while( not flock $lockfile_fh, (LOCK_EX|LOCK_NB) ) {
    warn "couldn't lock lockfile \"$lockfile,\" waiting for a turn...\n";
    sleep 5;
}
open my $output, ">", $output_filename or die "error opening output file \"$output_filename\": $!";

# now lets change the channel, now compatable with up to 4 digits
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


#systemx(echo,$show_length);
#systemx(echo,$buffer_time);
#systemx(echo,$show_length-$buffer_time);
#die;

#capture native AVS format h264 AAC
FFMPEG: {
    local $SIG{PIPE} = sub { die "execution failure while forking ffmpeg!\n"; };

    my @cmd = ('ffmpeg',

        "-y",                                     # it's ok to overwrite the output file
        "-i"      => $video_device,               # the input device
        "-vcodec" => "copy",                      # copy the video codec without transcoding, probably asking to much to call a specific encoder for real time capture
        "-acodec" => "copy",                      # what do you know, AAC is playable by default by the internal myth player
        "-t"      => $show_length-$buffer_time,   # -t record for this many seconds ... $o{t} was multiplied by 60 and is in minutes....minus buffer/recovery time

    $output_filename);

    my $base = basename($output_filename);
    my ($output_filehandle, $stdout, $stderr);
    my $pid = open3($output_filehandle, $stdout, $stderr, @cmd);

    close $output_filehandle; # tell ffmpeg to ignore userinput on stdin

    if( $group ) {
        if( my $gid = getgrnam($group) ) {
            chown $<, $gid, $output_filename or warn "couldn't change group of output file: $!";

        } else {
            warn "couldn't locate group \"$group\"\n";
        }
    }

    # TODO: there should be a config option for the location of the logs and we
    # should consider using syslogging features if users are of a mind to use
    # that sort of stuff.

    open my $log, ">", "/tmp/$base.log" or die $!;
    print $log localtime() . "(0): $_" while <$stdout>;

    # NOTE: from manpage, "If CHLD_ERR is false, or the same file descriptor as
    # CHLD_OUT, then STDOUT and STDERR of the child are on the same
    # filehandle." -- solves a concurrency problem anyway.  Awesome.
    # ### print $log localtime() . "(1): $_" while <$stderr>;

    waitpid($pid, 0); # ignore the return value... it probably returned.  (may also cause problems later)
                      # ffmpeg exit status is returned in $?

    if( $? ) {
        move($output_filename, "$output_path/$output_basename-err"); # if this fails, it doesn't really matter
        die "ffmpeg error, see tmp error log dump (/tmp/$base.log) for further information, video moved to: $output_path/$output_basename-err\n";
    }

    # no # flock $lockfile_fh, LOCK_UN or die $!; # seems like a good idea, but is actually a bad practice, long story
    close $lockfile_fh; # release the lock for the next process
}

# now let's import it into the mythtv database
# XXX: I reordered this to make a smarter flow, and altered the -m docs to match
if( defined $myth_import ) {
    if ($myth_import == 2) {
        # -m 2 means we transcode to native format
        my $transcode_basename = $output_basename;
           $transcode_basename =~ s/\.\Q$file_ext\E$/.mpg/;
        my $transcode_filename = "$output_path/$transcode_basename";

        unless( -f $transcode_filename ) {
            systemx('ffmpeg',

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

        # XXX: is it ok to do this before the import?
        systemx("mythcommflag","-f","$output_path/$channel\_$commflag_name.$file_ext");
        systemx('echo',"$output_basename");
        systemx('echo',"$output_path");
        systemx('echo',"$output_path/$channel\_$commflag_name.$file_ext");
    }

    # -m 1 and -m 2 both need a rebuilddatabase call

    # XXX: myth.rebuilddatabase.pl must be unziped and installed with correct perms somewhere in the path
    # mythbuntu distributes it in gz format to this location, however, your distro may be different
    # /usr/share/doc/mythtv-backend/contrib/myth.rebuilddatabase.pl.gz

    # import into MythTV mysql database so it is listed with all your other recorded shows
    systemx("myth.rebuilddatabase.pl",
        "--dbhost", "localhost", "--pass", $mysql_password, "--dir", $output_path, "--file", $output_basename, 
        "--answer", "y", "--answer", $channel, "--answer", $o{n}, "--answer", $subtitle, 
        "--answer", $description, "--answer", $start_time, "--answer", "Default", 
        "--answer", ($show_length)/60, "--answer", "y");

    # to be sure the recorded file plays well, lets do a (non-reencoding) transcode of the file
    # XXX: we do this after import in any import mode?  is that right?  Should it go before the import?
    systemx('mythtranscode', 
        "--mpeg2", "--buildindex", "--allkeys", "--showprogress", "--infile", 
        "$output_path/$channel\_$commflag_name.$file_ext");
}

# some database cleanup only if there are files that exist without entries or entries that exist without files
#systemx("myth.find_orphans.pl", "--dodbdelete", "--pass", $mysql_password);

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
    -H full help

    -b buffer/recovery time
    -c channel
    -d show description
    -f fork/daemonize
    -g group
    -L lockfile
    -m mythtv mysql import option (requires -p)
    -n show name
    -o output path
    -p mysql password (may require -o and/or -m)
    -r remote device
    -s subtitle description
    -t minutes (default 30)
    -v video device (default /dev/video0)
    -x file extension (default ts)

=head1 OPTIONS

=over

=item B<-b>

buffer/recovery time in seconds needed between recordings to reset for next
show default 1 second per 1 minute of recording time

=item B<-c>

channel, (default is nothing, just record whatever is on at the time)

=item B<-d>

description detail (default imported by HD PVR)

=item B<-f>

fork/daemonize (fork/detatch and run in background)

=item B<-g>

group to chgroup files to after running ffmpeg (default: mythtv if it exists,
'0' to disable)

=item B<-L>

lockfile location (default: /tmp/.vd-pl.lock)

=item B<-m>

mysql import type 1 and 2 requires -p

When -m isn't specified, this script simply does a raw dump to output folder
(-o).  Recording will be available for manual play as soon as recording starts,
will NOT show up in mythtv mysql "recorded shows" list, best dumped to default
MythVideo Gallery folder.

=over

=item B<1>

The output folder (-o) must be where mythtv recordings are stored by default.
Shows will be imported into mysql imediately after they are done recording in
raw format.  Requires mysql password (-p) switch!

=item B<2>

Same as 1, but shows will be converted to mythtv native mpeg2 format with
commercial flagging points.  They will also show up in the recorded shows list
after mpeg2 conversion (time will vary based on CPU).  Requires mysql password
(-p) switch.

=back

=item B<-n>

name of file, also used as title (default manual_record)

=item B<-o>

output path where you want shows to be placed needs / at end (default
/var/lib/mythtv/videos/)

=item B<-p>

mysql password, default is blank.  If you supply a password, will attempt to
import into MythTV mysql!  Found in Frontend -> Utilities/Setup->Setup->General
You need supply -o, which needs to be the path to your MythTV recorded shows folder.
You should use -m (1 or 2).  If -m switch is not used, (-m 1) is assumed.

=item B<-r>

remote device to be controled by IR transmitter, change in MythTV Control
Centre, look at /etc/lircd.conf for the chosen device blaster file that
contains the name to use here (default dish)

=item B<-s>

subtitle description (default recorded by HD PVR)

=item B<-t>

minutes (default 30)

=item B<-v>

video device (default /dev/video0)

=item B<-x>

file extension (default ts, ts gives mpeg-ts container to match mythtv's
container, will change to mpg after re-encoding video)

=back

=head1 COPYRIGHT

Copyright 2009 -- David Stoll and Paul Miller

GPL

=head1 REPORTING BUGS

C<http://groups.google.com/group/videodump-pl>

=head1 REPOSITORY

C<http://github.com/jettero/videodump-pl>

=head1 SEE ALSO

perl(1), ffmpeg(1)

=cut

# stolen from IPC::System::Simple (partially)
use Carp;
sub systemx {
    my $command = shift;
    CORE::system { $command } $command, @_;

    croak "child process failed to execute" if $? == -1;
    croak "child process returned error status" if $? != 0;
}
