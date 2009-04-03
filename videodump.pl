#!/usr/bin/perl

# videodump for Hauppauge HD PVR 1212
# edited as of April 2, 2009 by David

use strict;
use Fcntl qw(:flock);
use Getopt::Std;
use HTTP::Date;

my %o;
getopts("t:b:n:s:x:p:o:c:r:", \%o) or die "bad options";
# -t minutes (default 30)
# -b 1024 byte blocks to read at a time (default 8)
# -n name of file, also used as title (default manual_record)
# -s subtitle description (default recorded by HD PVR)
# -d description detail (default imported by HD PVR)
# -v video device (default /dev/video0)
# -x file extension (default mkv, will change to mpg when mpg encoding works)
# -p mysql password, default is blank, so you need one! found in frontend -> Utilities/Setup->Setup->General
# -o output path where shows are normally stored, needs / at the end (default /recordings/Default/)
# -c channel, (default is nothing, just record whatever is on at the time)
# -r remote device to be controled by IR transmitter, change in MythTV Control Centre, look /etc/lircd.conf for the chosen device blaster file that contains the name to use here (default dish)

my $show_length = ($o{t} || 30)*60;
#my $stop_time = time + ($o{t} || $length_default)*60; #used for the "while" method of video capture below
my $name = $o{n} || "manual_record";
my $subtitle = $o{s} || "recorded by HD PVR videodump";
my $description = $o{d} || "imported by HD PVR videodump";
my $bs = $o{b}*1024 || 8192;
my $video_device = $o{v} || '/dev/video0';
my $file_ext = $o{x} || "mkv";
my $mysql_password = $o{p} || ""; # xfPbTC5xgx
my $output_path = $o{o} || "/recordings/Default/"; #for later importation into mythtv mysql
my $channel = $o{c} || "";
my $remote = $o{r} || "dish";

my $output_filename = "$o{n}.$file_ext";

#setup time in correct format "YYYY-MM-DD HH:MM:SS"
my ($date,$time) = split(" ",HTTP::Date::time2iso());
my ($hour,$min,$sec) = split(":",$time);
my $start_time = "$date $hour:$min:$sec";


#lock the source and make sure it isn't currently being used
open my $video_source, "<", $video_device or die "error opening source video device($video_device): $!";
flock $video_source, (LOCK_EX|LOCK_NB) or die "couldn't lock source video device, exiting\n";
open my $output, ">", $output_filename or die "error opening source video device($output_filename): $!";


# now lets change the channel
sub change_channel {
        my($channel_digit) = @_;
        system ("irsend SEND_ONCE $remote $channel_digit");
        sleep 1;
}

sleep 1;
if (length($channel) > 2) {
        change_channel(substr($channel,0,1));
        change_channel(substr($channel,1,1));
        change_channel(substr($channel,2,1));
} elsif (length($channel) > 1) {
        change_channel(substr($channel,0,1));
        change_channel(substr($channel,1,1));
} else {
        change_channel(substr($channel,0,1));
}

# may or may not need to send the ENTER command after the channel numbers are sent
# remove comment from next line if necessary, may need to try OK instead of ENTER.
#system ("irsend SEND_ONCE $remote ENTER");


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
system('/usr/bin/ffmpeg',"-y","-i",$video_device,"-vcodec","copy","-acodec","ac3","-ab","256k","-vb","10000k","-f","matroska","-t",$show_length,$output_filename);

#until I can figure out how to capture or transcode to mpg, move raw .mkv file to gallery folder
system('mv',$output_filename,'/var/lib/mythtv/videos/');




# lets fix the mpg to be sure it doesn't have any errors
# this may not be the best way to do it
# first optimize database, the script is going to need 755 perms or something similar
#system("perl","/usr/share/doc/mythtv-backend/contrib/optimize_mythdb.pl");


# move it to the default location for normal recorded shows
#system('mv', "$output_filename", "$output_path$output_filename") == 0 or die "file doesn't exist?";


# this script creates the video file as the current user, not the mythtv user, so mythtv frontend can't delete it
# if this script is run as sudo, it can change the owner
#system("sudo","chown","mythtv:mythtv","$output_path$output_filename");


# now that we know where it is, we can fix any errors in file that was just created
#system('/usr/bin/mythtranscode',"--mpeg2 --buildindex --allkeys --showprogress --infile","$output_path$output_filename");



# now let's import it into the mythtv database
#system("perl","/usr/share/doc/mythtv-backend/contrib/myth.rebuilddatabase.pl","--dbhost","localhost","--pass","$mysql_password","--dir","$output_path","--file","$output_filename","--answer","y","--answer","$channel","--answer","$o{n}","--answer","$subtitle","--answer","$description","--answer","$start_time","--answer","Default","--answer","$show_length","--answer","y");

# some database cleanup only if there are files that exist without entries or entries that exist without files
# unfortuntatly has to be run as sudo, so if script is run as sudo, this will also work
#system("sudo /usr/share/doc/mythtv-backend/contrib/myth.find_orphans.pl --dodelete --pass","mysql_password");





