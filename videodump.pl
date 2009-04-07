#!/usr/bin/perl

# videodump for Hauppauge HD PVR 1212

use strict;
use Fcntl qw(:flock);
use Getopt::Std;
use HTTP::Date;
use POSIX qw(setsid);
use File::Spec;
use File::Basename;
use File::Copy;

our $VERSION = "1.1";

my %o;

getopts("dht:v:b:n:s:x:p:o:c:r:", \%o) or HELP_MESSAGE(); HELP_MESSAGE() if $o{h};
sub HELP_MESSAGE {
    my $indent = "\n" . (" " x 4);

    print "This is videodump.pl $VERSION\n\n";
    print "Options and switches for videodump.pl:\n";
    print "  -d daemonize (detatch and run in background)\n";
    print "  -t minutes (default 30)\n";
    print "  -b 1024 byte blocks to read at a time (default 8)\n";
    print "  -n name of file, also used as title (default manual_record)\n";
    print "  -s subtitle description (default recorded by HD PVR)\n";
    print "  -d description detail (default imported by HD PVR)\n";
    print "  -v video device (default /dev/video0)\n";
    print "  -x file extension (default mkv, will change to mpg when mpg$indent encoding works)\n";
    print "  -p mysql password, default is blank, so you need one! found$indent rontend -> Utilities/Setup->Setup->General\n";
    print "  -o output path where shows are normally stored, needs / at$indent end (default /recordings/Default/)\n";
    print "  -c channel, (default is nothing, just record whatever is on$indent at the time)\n";
    print "  -r remote device to be controled by IR transmitter, change in$indent ", 
                "MythTV Control Centre, look /etc/lircd.conf for the chosen device$indent blaster ",
                "file that contains the name to use here (default dish)\n";

    exit 0;
}

my $show_length    = ($o{t} || 30)*60;
my $name           = $o{n} || "manual_record";
my $subtitle       = $o{s} || "recorded by HD PVR videodump";
my $description    = $o{d} || "imported by HD PVR videodump";
my $bs             = $o{b}*1024 || 8192;
my $video_device   = $o{v} || '/dev/video0';
my $file_ext       = $o{x} || "mp4";
my $mysql_password = $o{p} || ""; # xfPbTC5xgx
my $output_path    = $o{o} || '/var/lib/mythtv/videos/'; # until I can figure out how to capture or transcode to mpg, move video file to gallery folder
my $channel        = $o{c} || "";
my $remote         = $o{r} || "dish";

# NOTE make relative paths absolute before we daemonize (if applicable)
my $output_filename = File::Spec->rel2abs("$name.$file_ext");
   $output_path     = File::Spec->rel2abs($output_path);
   $video_device    = File::Spec->rel2abs($video_device);

if( $o{d} ) {
    # daemonize -- copied from http://www.webreference.com/perl/tutorial/9/3.html
    defined(my $pid = fork) or die "can't fork: $!";
    exit if $pid;
    setsid() or die "can't create a new session: $!";

    close STDOUT; # NOTE: normally a daemonized process will do this...
    close STDINT; # the reason I added it today was that many of the ffmpeg examples
                  # use ffmpeg -b -l -a -h < /dev/null & when they background things.
}

#setup time in correct format "YYYY-MM-DD HH:MM:SS"
my ($date, $time)      = split(" ", HTTP::Date::time2iso());
my ($hour, $min, $sec) = split(":", $time);
my $start_time         = "$date $hour:$min:$sec";


#lock the source and make sure it isn't currently being used
open my $video_source, "<", $video_device or die "error opening source video device \"$video_device\": $!";
flock $video_source, (LOCK_EX|LOCK_NB) or die "couldn't lock source video device: $!";
open my $output, ">", $output_filename or die "error opening output file \"$output_filename\": $!";

# now lets change the channel
sub change_channel {
    my($channel_digit) = @_;

#some set top boxes need to be woken up
    system ("irsend SEND_ONCE $remote SELECT");
    sleep 1; # give it a second to wake up before sending the digits

    system ("irsend SEND_ONCE $remote $channel_digit");
    sleep 1;
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


# video dumping
#my $ofh =
#    select $video_source; $|=1; # killing buffering
#    select $output; $|=1; # (to make sure we read as fast as possible)
#    select $ofh;

#my $buf; # (we kinda buffer anyway...)
#while(read $video_source, $buf, $bs) {
#    print $output $buf;
#    last if time > $stop_time;
#}



#another way to capture video, but mpg capture doesn't seem to work, freezes at approx 5 seconds
#system('/usr/bin/ffmpeg',"-y","-t","3","-b","10000k","-f","oss","-f","mpegts","-i",$video_source,$output_filename);
#system('/usr/bin/ffmpeg',"-y","-i",$video_device,"-acodec","ac3","-ab","256k","-vb","10000k","-f","matroska","-t",$show_length,$output_filename);
#system(/usr/bin/ffmpeg,"-y","-i",$video_device,"-vcodec","mpeg2video","-b","10000k","-acodec","ac3","-ab","256k","-f","vob","-t",$show_length,$output_filename);

#system('cd','/var/lib/mythvideos/');

#capture native mkv h.264 format
my @cmd = ('/usr/bin/ffmpeg',

    "-y",                        # it's ok to overwrite the output file
    "-i"      => $video_device,  # the input device
    "-vcodec" => "copy",         # copy the video codec without transcoding
    "-acodec" => "copy",         # ... the audio codec
    "-t"      => $show_length,   # -t record for this many seconds ... $o{t} is multiplied by 60 and is in minutes

$output_filename);
open my $cmdfh, "|-", @cmd or die "error with popen(ffmpeg): $!";
if( !close($cmdfh) and !$! ) {
    warn "ffmpeg error, see stdout/stderr for further information";

    my $base = basename($output_filename);
    move($output_filename, "$output_path/$base.ffmpegerr") or warn "couldn't move file: $!";

} else {
    move($output_filename, $output_path) or warn "couldn't move file: $!";
}


# lets fix the mpg to be sure it doesn't have any errors
# this may not be the best way to do it
# first optimize database, the script is going to need 755 perms or something similar
# NOTE: script won't need 755 if you fork and use $^X
#system($^X,"/usr/share/doc/mythtv-backend/contrib/optimize_mythdb.pl");


# this script creates the video file as the current user, not the mythtv user, so mythtv frontend can't delete it
# if this script is run as sudo, it can change the owner
#system("sudo","chown","mythtv:mythtv","$output_path$output_filename"); # should be done with perl's chown()


# now that we know where it is, we can fix any errors in file that was just created
#system('/usr/bin/mythtranscode',"--mpeg2 --buildindex --allkeys --showprogress --infile","$output_path$output_filename");



# now let's import it into the mythtv database
#system($^X,"/usr/share/doc/mythtv-backend/contrib/myth.rebuilddatabase.pl","--dbhost","localhost","--pass","$mysql_password","--dir","$output_path","--file","$output_filename","--answer","y","--answer","$channel","--answer","$o{n}","--answer","$subtitle","--answer","$description","--answer","$start_time","--answer","Default","--answer","$show_length","--answer","y");

# some database cleanup only if there are files that exist without entries or entries that exist without files
# unfortuntatly has to be run as sudo, so if script is run as sudo, this will also work
#system("sudo /usr/share/doc/mythtv-backend/contrib/myth.find_orphans.pl --dodelete --pass","mysql_password");
