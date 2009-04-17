#!/usr/bin/perl

# videodump for Hauppauge HD PVR 1212 by David & Paul

use strict;
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

our $VERSION = "1.42";

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

if (($myth_import == 1 or $myth_import == 2) and not defined $mysql_password) {
    die "If you want me to import, you need to supply your mysql password!";
}

umask 0007 if $group; # umask 0007 leaves group write bit on, good when using group chown() mode

# NOTE: we're being paranoid about input filenames, it's a good habit.

$output_path  = File::Spec->rel2abs($output_path);
$output_path  = getcwd() unless -d $output_path and -w _;
$video_device = File::Spec->rel2abs($video_device);

my $start_time      = strftime('%y-%m-%d %H:%M:%S', localtime); # need colons for future import into mythtv database, not file name.
my $start_time_name = strftime('%y-%m-%d %l.%M%P', localtime);

my $output_basename = basename("$name $start_time_name $channel.$file_ext"); # filename includes date, time and channel, colons can cause issues ouside of linux
my $output_filename = File::Spec->rel2abs( File::Spec->catfile($output_path, $output_basename) );

if( $o{f} ) {
    # fork/daemonize -- copied from http://www.webreference.com/perl/tutorial/9/3.html
    defined(my $pid = fork) or die "can't fork: $!";
    exit if $pid;
    setsid() or die "can't create a new session: $!";

    close STDOUT; # NOTE: normally a daemonized process will do this...
    close STDINT; # the reason I added it today was that many of the ffmpeg examples
                  # use ffmpeg -b -l -a -h < /dev/null & when they background things.
}



#lock the source and make sure it isn't currently being used
open my $lockfile_fh, ">", $lockfile or die "error opening lockfile \"$lockfile\": $!";
while( not flock $lockfile_fh, (LOCK_EX|LOCK_NB) ) {
    warn "couldn't lock lockfile \"$lockfile,\" waiting for a turn...\n";
    sleep 5;
}
open my $output, ">", $output_filename or die "error opening output file \"$output_filename\": $!";

# now lets change the channel
    system ("irsend SEND_ONCE $remote SELECT"); # needs to be outside of sub change_channel
    sleep 1; # give it a second to wake up before sending the digits

sub change_channel {
    my($channel_digit) = @_;

#some set top boxes need to be woken up
    system ("irsend SEND_ONCE $remote $channel_digit");
    sleep 0.2; # channel change speed, 1 sec is too long, some boxes may timeout
}

sleep 1;

if (length($channel) > 2) {
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
#system ("irsend SEND_ONCE $remote SELECT");


#system(echo,$show_length);
#system(echo,$buffer_time);
#system(echo,$show_length-$buffer_time);
#die;

#capture native AVS format h264 AAC
FFMPEG: {
    local $SIG{PIPE} = sub { die "execution failure while forking ffmpeg!\n"; };

    my @cmd = ('/usr/bin/ffmpeg',

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
    print $log localtime() . "(0): $_" while <$stdout>; # this is fine for now, but it may cause problems later
    print $log localtime() . "(1): $_" while <$stderr>; #  specifically, lots of stderr may jam the pipe() before
                                                        #   we get around to reading it

    waitpid($pid, 0); # ignore the return value... it probably returned.  (may also cause problems later)
                      # ffmpeg exit status is returned in $?

    if( $? ) {
        warn "ffmpeg error, see stdout/stderr logs for further information";
        move($output_filename, "$output_path/$output_basename-err"); # if this fails, it doesn't really matter
    }

    # no # flock $lockfile_fh, LOCK_UN or die $!; # seems like a good idea, but is actually a bad practice, long story
    close $lockfile_fh; # release the lock for the next process
}



# now that we know where it is, we can fix any errors in file that was just created
#system('/usr/bin/mythtranscode',"--mpeg2 --buildindex --allkeys --showprogress --infile","$output_path$output_filename");

if ($myth_import = 2) {
system('ffmpeg',
     "-i" => $output_filename,
     "-acodec" => "ac3", "-ab" => "192k",
     "-vcodec" => "mpeg2video", "-b" => "10.0M", "-cmp" => 2, "-subcmp" => 2,
     "-mbd" => 2, "-trellis" => 1,
     "$output_path/$name", $start_time_name, $channel, "re-encoded.mpg");

# need command here to delete original file if the above conversion was sucessfull

my $output_basename = "$name $start_time_name $channel re-encoded.mpg"; # the new target file name
my $output_filename = "$output_path/$output_basename";# the new target file name and path
system("echo $output_basename");
system("echo $output_filename");

# lets fix the mpg to be sure it doesn't have any errors
# this may not be the best way to do it
# first optimize database, the script is going to need 755 perms or something similar
# NOTE: script won't need 755 if you fork and use $^X
#system($^X,"/usr/share/doc/mythtv-backend/contrib/optimize_mythdb.pl");
 } 


# now let's import it into the mythtv database
if( $mysql_password ) {
    # XXX: myth.rebuilddatabase.pl must be unziped and installed with correct perms somewhere in the path
    # mythbuntu distributes it in gz format to this location, however, your distro may be different
    # /usr/share/doc/mythtv-backend/contrib/myth.rebuilddatabase.pl.gz

    # import into MythTV mysql database so it is listed with all your other recorded shows
    system("myth.rebuilddatabase.pl", 
        "--dbhost", "localhost", "--pass", $mysql_password, "--dir", $output_path, "--file", $output_basename, 
        "--answer", "y", "--answer", $channel, "--answer", $o{n}, "--answer", $subtitle, 
        "--answer", $description, "--answer", $start_time, "--answer", "Default", 
        "--answer", ($show_length)/60, "--answer", "y");
}


# some database cleanup only if there are files that exist without entries or entries that exist without files
#system("/usr/share/doc/mythtv-backend/contrib/myth.find_orphans.pl --dodbdelete --pass","mysql_password");

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

lockfile location (default: 0), 1 and 2 require -p

=over

=item B<0>

Raw dump to output folder (-o), recording will be available for manual play as
soon as recording starts, will NOT show up in mythtv mysql "recorded shows"
list, best dumped to default MythVideo Gallery folder.

=item B<1>

Same as 0, but the output folder (-o) must be where mythtv recordings are
stored by default, will be imported into mysql imediately after it is done
recording in raw format.  Requires mysql password (-p) switch.

=item B<2>

Same as 1, but will be converted to mythtv native mpeg2 format with commercial
flagging points, will show up in the recorded shows list after mpeg2 conversion
(time will vary based on CPU).  Requires mysql password (-p) switch.

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
