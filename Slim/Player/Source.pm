package Slim::Player::Source;

# SlimServer Copyright (C) 2001,2002,2003 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use File::Spec::Functions qw(:ALL);
use FileHandle;
use FindBin qw($Bin);
use IO::Socket qw(:DEFAULT :crlf);
use Time::HiRes;

BEGIN {
	if ($^O =~ /Win32/) {
		*EWOULDBLOCK = sub () { 10035 };
		*EINPROGRESS = sub () { 10036 };
	} else {
		require Errno;
		import Errno qw(EWOULDBLOCK EINPROGRESS);
	}
}

use Slim::Control::Command;
use Slim::Display::Display;
use Slim::Utils::Misc;
use Slim::Utils::Scan;
use Slim::Utils::Strings qw(string);

my $TRICKSEGMENTLENGTH = 1.0;
				
my %commandTable = ();

sub loadConversionTables {
	my @convertFiles;
	$::d_source && msg("loading conversion config files...\n");
	
	push @convertFiles, catdir($Bin, 'convert.conf');
	if (Slim::Utils::OSDetect::OS() eq 'mac') {
		push @convertFiles, $ENV{'HOME'} . "/Library/SlimDevices/convert.conf";
		push @convertFiles, "/Library/SlimDevices/convert.conf";
	}
	
	foreach my $convertFileName (@convertFiles) {
		if (open my $convertFile, "<$convertFileName") {
			while (1) {
				my $line = <$convertFile>;
				last if (!defined($line));
				
				my $command = undef;
				
				# get rid of comments and leading and trailing white space
				$line =~ s/#.*$//;
				$line =~ s/^\s//;
				$line =~ s/\s$//;
	
				if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) {
					my $inputtype = $1;
					my $outputtype = $2;
					my $clienttype = $3;
					my $clientid = lc($4);
					$command = <$convertFile>;
					$command =~ s/^\s//;
					$command =~ s/\s$//;
					$::d_source && msg( "input: '$inputtype' output: '$outputtype' clienttype: '$clienttype': clientid: '$clientid': '$command'\n");					
					if (defined($command)) {
						$commandTable{"$inputtype-$outputtype-$clienttype-$clientid"} = $command;
					}
				}
			}
			close $convertFile;
		}
	}
}

sub init {
	loadConversionTables();
	Slim::Networking::Slimproto::setEventCallback('STMu', \&underrun);
}

# rate can be negative for rew, zero for pause, 1 for playback and greater than one for ffwd
sub rate {
	my ($client, $newrate) = @_;
	if (!defined($newrate)) {
		return $client->rate;
	}
	my $oldrate = $client->rate();
	
	# restart playback if we've changed and we're not pausing or unpauseing
	if ($oldrate != $newrate) {  		
		$::d_source && msg("switching rate from $oldrate to $newrate\n") && bt();
	 	if ($newrate != 0) {
	 		$::d_source && msg("rate change, jumping to the current position in order to restart the stream\n");
			gototime($client, "+0");
		}
	}
	$client->rate($newrate);
}

sub time2offset {
	my $client = shift;
	my $time = shift;

	my $size = $client->songtotalbytes();
	my $duration = $client->songduration();

	my $byterate;

	if (!$duration) {
		$byterate = 0;
	} else {
		$byterate = $size / $duration;
	}
	my $offset = int($byterate * $time);
	
	return $offset;
}


# fractional progress (0 - 1.0) of playback in the current song.
sub progress {
	my $client = shift;
	
	return 0 if (!$client->songduration);
	return songTime($client) / $client->songduration;
}

sub songTime {
	my ($client) = shift;

	$client = Slim::Player::Sync::masterOrSelf($client);

	if ($client->mp3filehandleIsSocket) {
		my $startTime = $client->remoteStreamStartTime;
		if ($startTime) {
			return Time::HiRes::time() - $startTime;
		} else {
			return 0;
		}
	}

	my $size = $client->songtotalbytes;
	my $duration = $client->songduration;
	
	my $byterate;
	if (!$duration) {
		$byterate = 0;
	} else {
		$byterate = $size / $duration;
	}

	my $bytesReceived = $client->bytesReceived() || 0;
	my $fullness = $client->bufferFullness() || 0;
	my $realpos =  $bytesReceived - $fullness;
	
	$::d_source && msg("realpos $realpos calcuated from bytes received: " . $client->bytesReceived() . " minus buffer fullness: " . $client->bufferFullness() . "\n");
	
	if ($realpos<0) {
		$::d_source && msg("Negative position calculated, we are still playing out the previous song.\n");	
		$realpos = 0;
	}

	my $songtime;
	my $rate = $client->rate;
	my $startStream =  $client->songStartStreamTime();

	if (!$size) {
		$songtime = 0;
	} else {
		$songtime = ($realpos / $size * $duration * $rate) + $startStream;
	}

	$::d_source && msg( "songTime: $songtime = ($realpos(realpos) / $size(size) * $duration(duration) * $rate(rate)) + $startStream(time offset of started stream)\n");

	return($songtime);
}	


# playmode - start playing, pause or stop
sub playmode {
	my($client, $newmode) = @_;

	assert($client);

	if (!defined($newmode)) {
		return $client->playmode;
	}
	
	$::d_source && $newmode && msg($client->id() . ": Switching to mode $newmode\n");

	my $prevmode = $client->playmode;

	if ($newmode eq $prevmode) {
		$::d_source && msg(" Already in playmode $newmode : ignoring mode change\n");
	} else {
		if ($newmode eq "pause" && $client->rate != 1) {
			$newmode = "pausenow";
		}
		
		# if we're playing, then open the new song the master.		
		if ($newmode eq "play") {
			my $opened;
			
			# if the player is off, we automatically power on when we start to play
			if (!$client->power()) {
				$client->power(1);
			}
			
			$opened = openSong(Slim::Player::Sync::masterOrSelf($client));

			# if we couldn't open the song, then stop...
			if (!$opened) {
				$::d_source && msg("Couldn't open song.  Stopping.\n");
				$newmode = "stop";
			}
		}
		
		# when we change modes, make sure we do it to all the synced clients.
		foreach my $everyclient ($client, Slim::Player::Sync::syncedWith($client)) {
			$::d_source && msg(" New play mode: " . $newmode . "\n");
			
			# wake up the display if we've switched modes.
			if ($everyclient->isPlayer()) { Slim::Buttons::ScreenSaver::wakeup($everyclient); };
			
			# when you resume, you go back to play mode
			if (($newmode eq "resume") ||($newmode eq "resumenow")) {
				$everyclient->playmode("play");
				
			} elsif ($newmode eq "pausenow") {
				$everyclient->playmode("pause");
				
			} elsif ($newmode =~ /^playout/) {
				$everyclient->playmode("stop");
				closeSong($everyclient);
			} else {
				$everyclient->playmode($newmode);
			}
	
			if ($newmode eq "stop") {
				$everyclient->currentplayingsong("");
				$::d_source && msg("Stopping and clearing out old chunks for client " . $everyclient->id() . "\n");
				@{$everyclient->chunks} = ();

				$everyclient->stop();
				closeSong($everyclient);
			} elsif ($newmode eq "play") {
				$everyclient->readytosync(0);
				$everyclient->volume(Slim::Utils::Prefs::clientGet($everyclient, "volume"));
				$everyclient->play(Slim::Player::Sync::isSynced($everyclient));				
			} elsif ($newmode eq "pause") {
				# since we can't count on the accuracy of the fade timers, we unfade them all, but the master calls back to pause everybody
				if ($everyclient eq $client) {
					$everyclient->fade_volume(-0.3125, \&pauseSynced, [$client]);
				} else {
					$everyclient->fade_volume(-0.3125);
				}				
				
			} elsif ($newmode eq "pausenow") {
				$everyclient->pause();
			} elsif ($newmode eq "resumenow") {
				$everyclient->volume(Slim::Utils::Prefs::clientGet($everyclient, "volume"));
				$everyclient->resume();
				
			} elsif ($newmode eq "resume") {
				# set volume to 0 to make sure fade works properly
				$everyclient->volume(0);
				$everyclient->resume();
				$everyclient->fade_volume(.3125);
				
			} elsif ($newmode =~ /^playout/) {
				$everyclient->playout();

			} else {
				$::d_source && msg(" Unknown play mode: " . $everyclient->playmode . "\n");
				return $everyclient->playmode();
			}
			
			Slim::Player::Playlist::refreshPlaylist($everyclient);
		}
	}
	$::d_source && msg($client->id() . ": Current playmode: " . $client->playmode() . "\n");

	return $client->playmode();
}

sub underrun {
	my $client = shift;
	# the only way we'll get an underrun event while stopped is if we were playing out.  so we need to open the next item and play it!
	if ($client && $client->playmode eq 'playout-play') {
		openNext($client);
		playmode($client, 'play');
	}
}

sub nextChunk {
	use bytes;

	my $client = shift;
	my $maxChunkSize = shift;
	my $chunkRef;
	my $i;
		
	# if there's a chunk in the queue, then use it.
	if (scalar(@{$client->chunks})) {
		$chunkRef = shift @{$client->chunks};
	} else {
		#otherwise, read a new chunk
		my $readfrom = Slim::Player::Sync::masterOrSelf($client);
			
		$chunkRef = readNextChunk($readfrom, $maxChunkSize);
			
		if (defined($chunkRef)) {	
			# let everybody I'm synced with use this chunk
			foreach my $buddy (Slim::Player::Sync::syncedWith($client)) {
				push @{$buddy->chunks}, $chunkRef;
			}
		}
	}
	
	if (defined($chunkRef)) {
		my $len = length($$chunkRef);
		if (defined($chunkRef)) {
			my $len = length($$chunkRef);
			if ($len > $maxChunkSize) {
				$::d_playlist && msg("chunk too big, pushing the excess for later.\n");
				
				my $queued = substr($$chunkRef, $maxChunkSize - $len, $len - $maxChunkSize);
				unshift @{$client->chunks}, \$queued;
				
				my $returned = substr($$chunkRef, 0, $maxChunkSize);
				$chunkRef = \$returned;
			}
		}
	}
	
	return $chunkRef;
}



#
# jump to a particular time in the current song
#  should be dead-on for CBR, approximate for VBR
#  third argument determines whether this is an instant jump or wait until the
#   buffer gets around to it
#
sub gototime {
	my($client, $newtime) = @_;
	my $newoffset;
	my $oldtime;
	
	$client = Slim::Player::Sync::masterOrSelf($client);
	
	return if (!Slim::Player::Playlist::song($client));
	return if !defined($client->mp3filehandle);

	my $size = $client->songtotalbytes;
	my $duration = $client->songduration;

	return if (!$size || !$duration);

	$oldtime = songTime($client);

	if ($newtime =~ /^[\+\-]/) {
		$::d_source && msg("gototime: relative jump $newtime from current time $oldtime\n");
		$newtime += $oldtime;
	}
	
	$newoffset = time2offset($client, $newtime);
	
	$::d_source && msg("gototime: going to time $newtime, offset $newoffset from old time: $oldtime\n");

	# skip to the previous or next track as necessary
	if ($newoffset > $size) {
		my $rate = rate($client);
		jumpto($client, "+1");
		rate($client, $rate);
		$newtime = ($newoffset - $size) * $duration / $size;
		$::d_source && msg("gototime: skipping forward to the next track to time $newtime\n");
		gototime($client, $newtime);
		return;
	} elsif ($newoffset < 0) {
		my $rate = rate($client);
		while ($newtime < 0) {
			jumpto($client, "-1");
			rate($client, $rate);
			$newtime = $client->songduration - ((-$newoffset) * $duration / $size);
			$::d_source && msg("gototime: skipping backwards to the previous track to time $newtime\n");
		}
		gototime($client, $newtime);
		return;
	}
	foreach my $everybuddy ($client, Slim::Player::Sync::slaves($client)) {
		$::d_source && msg("gototime: stopping playback\n");
		$everybuddy->stop();
		@{$everybuddy->chunks} = ();
	}

	my $dataoffset =  $client->songoffset;
	$client->songBytes($newoffset);
	$client->lastskip($newoffset);
	$client->mp3filehandle->seek($newoffset+$dataoffset, 0);
	$client->songStartStreamTime($newtime);

	foreach my $everybuddy ($client, Slim::Player::Sync::slaves($client)) {
		$::d_source && msg("gototime: restarting playback\n");
		$everybuddy->readytosync(0);
		$everybuddy->play(Slim::Player::Sync::isSynced($client));
	}
}

# jumpto - set the current song to a given offset
sub jumpto {
	my($client, $offset) = @_;
	my($songcount) = Slim::Player::Playlist::count($client);
	if ($songcount == 0) {
		return;
	}

	playmode($client,"stop");
	if ($songcount != 1) {
		if ($offset =~ /[\+\-]\d+/) {
			currentSongIndex($client, currentSongIndex($client) + $offset);
			$::d_source && msgf("jumping by %s\n", $offset);
		} else {
			currentSongIndex($client, $offset);
			$::d_source && msgf("jumping to %s\n", $offset);
		}
	
		if ($songcount && currentSongIndex($client) >= $songcount) {
			currentSongIndex($client, currentSongIndex($client) % $songcount);
		}
		if ($songcount && currentSongIndex($client) < 0) {
			currentSongIndex($client, $songcount - ((0 - currentSongIndex($client)) % $songcount));
		}
	} else {
		currentSongIndex($client, 0);
	}
	playmode($client,"play");
}


################################################################################
# Private functions below. Do not call from outside this module.
################################################################################

# openNext returns 1 if it succeeded opening a new song, 
#                  0 if it stopped at the end of the list or failed to open the current song 
# note: Only call this with a master or solo client
sub openNext {
	$::d_source && msg("opening next song...\n"); 
	my $client = shift;
	my $result = 1;
	
	my $oldstreamformat = $client->streamformat;
	my $nextsong;
	closeSong($client);

	# we're at the end of a song, let's figure out which song to open up.
	# if we can't open a song, skip over it until we hit the end or a good song...
	do {
	
		if (Slim::Player::Playlist::repeat($client) == 2  && $result) {
			$nextsong = nextsong($client);
		} elsif (Slim::Player::Playlist::repeat($client) == 1 && $result) {
			#play the same song again
		} else {
			#stop at the end of the list
			if (currentSongIndex($client) == (Slim::Player::Playlist::count($client) - 1)) {
				playmode($client, $result ? 'playout-stop' : 'stop');
				$nextsong = 0;
				currentSongIndex($client, $nextsong);
				return 0;
			} else {
				$nextsong = nextsong($client);
			}
		}

		my ($command, $type, $newstreamformat) = getCommand($client, Slim::Player::Playlist::song($client, $nextsong));
		
		if ($oldstreamformat ne $newstreamformat && playmode($client) eq 'play') {
			$::d_source && msg("switching formats from $oldstreamformat to ". $newstreamformat. "--playing out \n");
			playmode($client, 'playout-play');
			return 0;
		} else {
			currentSongIndex($client, $nextsong);
			$result = openSong($client);
		}

		# if we're playing backwards, we need to start at the end of the file.
		if ($client->rate() < 0) {
			gototime($client, $client->songduration() - $TRICKSEGMENTLENGTH);
		}
		
	} while (!$result);
	
	# this is
	if ($result && Slim::Player::Sync::isSynced($client)) {
		my $silence = Slim::Web::HTTP::getStaticContent("html/silentpacket.mp3");
		my $count = int($client->buffersize() / length($silence)) + 1;
		my @fullbufferofsilence =  (\$silence) x $count;
		$::d_source && msg("stuffing " . scalar(@fullbufferofsilence) . " of silence into the buffers to sync.\n"); 
		# stuff silent packets to fill the buffers for each player
		foreach my $buddy ($client, Slim::Player::Sync::syncedWith($client)) {
			push @{$buddy->chunks}, (@fullbufferofsilence);
		}
		$client->resync(1); 
	}
	
	return $result;
}


sub currentSongIndex {
	my $client = shift;
	my $newindex = shift;

	$client = Slim::Player::Sync::masterOrSelf($client);
	
	if (defined($newindex)) {
		$client->currentsong($newindex);
	}
	
	return $client->currentsong;
}

# nextsong is for figuring out what the next song will be.
sub nextsong {
	my ($client) = @_;
	my $nextsong;
	my $currsong = currentSongIndex($client);
	
	return 0 if (Slim::Player::Playlist::count($client) == 0);
	
	my $direction = 1;
	
	if ($client->rate() < 0) { $direction = -1; }
	 
	$nextsong = currentSongIndex($client) + $direction;

	if ($nextsong >= Slim::Player::Playlist::count($client)) {
		# play the next song and start over if necessary
		if (Slim::Player::Playlist::shuffle($client) && 
			Slim::Player::Playlist::repeat($client) == 2 &&
			Slim::Utils::Prefs::get('reshuffleOnRepeat')) {
			
				Slim::Player::Playlist::reshuffle($client, 1);
		}
		$nextsong = 0;
	}
	
	if ($nextsong < 0) {
		$nextsong = Slim::Player::Playlist::count($client) - 1;
	}
	
	$::d_source && msg("the next song is number $nextsong, was $currsong\n");
	
	return $nextsong;
}

sub closeSong {
	my $client = shift;

	# close the previous handle to prevent leakage.
	if (defined $client->mp3filehandle()) {
		$client->mp3filehandle->close();
		$client->mp3filehandle(undef);
		$client->mp3filehandleIsSocket(0);
	}	
}

sub openSong {
	my $client = shift;

	# at the end of a song, reset the song time
	$client->songtotalbytes(0);
	$client->songduration(0);
	$client->bytesReceived(0);
	$client->songBytes(0);
	$client->lastskip(0);
	$client->songStartStreamTime(0);
	
	# reset shoutcast variables
	$client->shoutMetaInterval(0);
	$client->shoutMetaPointer(0);

	# mark htmlplaylist invalid so the current song changes
	$client->htmlstatusvalid(0);
	my $fullpath = '';

	# We are starting a new song, lets kill any animation so we see the correct new song.
	foreach my $everyclient ($client, Slim::Player::Sync::syncedWith($client)) { 
		Slim::Display::Animation::killAnimation($everyclient);
	}
	
	closeSong($client);
	
	$fullpath = Slim::Player::Playlist::song($client);

	unless ($fullpath) {
		return undef;
	}

	$::d_source && msg("openSong on: $fullpath\n");
	####################
	# parse the filetype

	if (Slim::Music::Info::isHTTPURL($fullpath)) {
		my $line1 = string('CONNECTING_FOR');
		my $line2 = Slim::Music::Info::standardTitle($client, Slim::Player::Playlist::song($client));			
		Slim::Display::Animation::showBriefly($client, $line1, $line2, undef,1);

		# we don't get the content type until after the stream is opened
		my $sock = Slim::Web::RemoteStream::openRemoteStream($fullpath, $client);
		if ($sock) {
			# if it's an mp3 stream, then let's stream it.
			if (Slim::Music::Info::isSong($fullpath)) {
				$client->mp3filehandle($sock);
				$client->mp3filehandleIsSocket(1);
				$client->remoteStreamStartTime(time());

				defined(Slim::Utils::Misc::blocking($sock,0)) || die "Cannot set remote stream nonblocking";

			# if it's one of our playlists, parse it...
			} elsif (Slim::Music::Info::isList($fullpath)) {
				$::d_source && msg("openSong on a remote list!\n");
				my @items;
				# handle the case that we've actually got a playlist in the list,
				# rather than a stream.

				# parse out the list
				@items = Slim::Formats::Parse::parseList($fullpath, $sock);
				
				# hack to preserve the title of a song redirected through a playlist
				if ( scalar(@items) == 1 && defined(Slim::Music::Info::title($fullpath))) {
				    Slim::Music::Info::setTitle($items[0], Slim::Music::Info::title($fullpath));
				} 
				
				# close the socket
				$sock->close();
				$sock = undef;
				$client->mp3filehandle(undef);

				# insert the list onto the playlist
				splice @{Slim::Player::Playlist::playList($client)}, currentSongIndex($client), 1, @items;

				# update the shuffle list
				Slim::Player::Playlist::reshuffle($client);

				# try to open the first item in the list, if there is one.
				return openSong($client);
			} else {
				$::d_source && msg("don't know how to handle content for $fullpath\n");
				$sock->close();
				$sock = undef;
				$client->mp3filehandle(undef);
			}
		} 
		
		if (!$sock) {
			$::d_source && msg("Remote stream failed to open, showing message.\n");
			$client->mp3filehandle(undef);
			
			my $line1 = string('PROBLEM_CONNECTING');
			my $line2 = Slim::Music::Info::standardTitle($client, Slim::Player::Playlist::song($client));			
			Slim::Display::Animation::showBriefly($client, $line1, $line2, 5, 1);
			return undef;
		}
	} elsif (Slim::Music::Info::isSong($fullpath)) {
	
		my $filepath;
		if (Slim::Music::Info::isFileURL($fullpath)) {
			$filepath = Slim::Utils::Misc::pathFromFileURL($fullpath);
		} else {
			$filepath = $fullpath;
		}
		
		my $size = Slim::Music::Info::size($fullpath);
		my $duration = Slim::Music::Info::durationSeconds($fullpath);
		my $offset = Slim::Music::Info::offset($fullpath);
		my $samplerate = Slim::Music::Info::samplerate($fullpath);
		$::d_source && msg("openSong: getting duration  $duration, size $size, and offset $offset for $fullpath\n");

		if (!$size || !$duration)  {
			$::d_source && msg("openSong: not bothering opening file with zero size or duration\n");
			return undef;
		}
		
		my ($command, $type, $format) = getCommand($client, $fullpath);
		
		$::d_source && msg("openSong: this is an $type file: $fullpath\n");
		$::d_source && msg("  file type: $type format: $format\n");
		$::d_source && msg("  command: $command\n");
		if (defined($command)) {

			# this case is when we play the file through as-is
			if ($command eq '-') {
				$client->mp3filehandle( FileHandle->new() );
		
				$::d_source && msg("openSong: opening file $filepath\n");
				if ($client->mp3filehandle->open($filepath)) {

					$::d_source && msg(" seeking in $offset into $filepath\n");
					if ($offset) {
						if (!seek ($client->mp3filehandle, $offset, 0) ) {
							msg("couldn't seek to $offset for $filepath");
						};
					}				
				} else { 
					$client->mp3filehandle(undef);
				}
							
			} else {
				
				my $fullCommand = $command;
	
				$fullCommand =~ s/\$FILE\$/"$filepath"/g;
				$fullCommand =~ s/\$URL\$/"$fullpath"/g;
				$fullCommand =~ s/\$RATE\$/$samplerate/g;
				
				my $swap = (unpack('n', pack('s', 1)) == 1) ? "" : "-x";
				$fullCommand =~ s/\$-x\$/$swap/g;
				
				my $bitrate = Slim::Utils::Prefs::get('transcodeBitrate');				
				$fullCommand =~ s/\$BITRATE\$/$bitrate/g;
				
				$fullCommand =~ s/\$([^\$]+)\$/'"' . Slim::Utils::Misc::findbin($1) . '"'/eg;

				$fullCommand .= (Slim::Utils::OSDetect::OS() eq 'win') ? "" : " &";

				$fullCommand .= ' |';
				
				$::d_source && msg("Using command for conversion: $fullCommand\n");

				$client->mp3filehandle( FileHandle->new() );
		
				$client->mp3filehandle->open($fullCommand);
				$client->mp3filehandleIsSocket(1);
				
				$client->remoteStreamStartTime(time());
				
				$size = $duration * $bitrate / 8;
				$offset = 0;
			}
		
			$client->songtotalbytes($size);
			$client->songduration($duration);
			$client->songoffset($offset);
			$client->streamformat($format);
			$::d_source && msg("Streaming with format: $format\n");
		
		} else {
			$::d_source && msg("Couldn't create command line for $type playback (command: $command) for $fullpath\n");
			return undef;
		}
	} else {
		$::d_source && msg("Song is of unrecognized type " . Slim::Music::Info::contentType($fullpath) . "! Stopping! $fullpath\n");
		return undef;
	}

	######################
	# make sure the filehandle was actually set
	if ($client->mp3filehandle()) {
		binmode($client->mp3filehandle());
		Slim::Web::History::record(Slim::Player::Playlist::song($client));
	} else {
		$::d_source && msg("Can't open [$fullpath] : $!");

		my $line1 = string('PROBLEM_OPENING');
		my $line2 = Slim::Music::Info::standardTitle($client, Slim::Player::Playlist::song($client));		
		Slim::Display::Animation::showBriefly($client, $line1, $line2, 5,1);
		return undef;
	}

	Slim::Player::Playlist::refreshPlaylist($client);
	
	Slim::Control::Command::executeCallback($client,  ['open', $fullpath]);

	return 1;
}

sub getCommand {
	my $client = shift;
	my $fullpath = shift;
	
	my $type = Slim::Music::Info::contentType($fullpath);
	my $player = $client->model();
	my $clientid = $client->id();
	my $command = undef;
	my $format = undef;
	
	foreach my $checkformat ($client->formats()) {
		$::d_source && msg("checking formats for: $type-$checkformat-$player-$clientid\n");
		# TODO: match partial wildcards in IP addresses.
		# use Data::Dumper; print Dumper(\%commandTable);
		$command = $commandTable{"$type-$checkformat-$player-$clientid"};
		if (defined($command)) {
			$::d_source && msg("Matched $type-checkformat-$player-$clientid\n");
		} else {
			$command = $commandTable{"$type-$checkformat-*-$clientid"};
		}
		if (defined $command) {
			$::d_source && msg("Matched $type-checkformat-$player-*\n");
		} else {
			$command = $commandTable{"$type-$checkformat-$player-*"};
		}
		if (defined($command)) {
			$::d_source && msg("Matched $type-checkformat-$player-*\n");
		} else {
			$command = $commandTable{"$type-$checkformat-*-*"};
		}
		$format = $checkformat;
		last if ($command);
	}

	if (!defined $command) {
		$::d_source && msg("******* Error:  Didn't find any command matches ******\n");
	}

	return ($command, $type, $format);
}

sub readNextChunk {
	my $client = shift;
	my $givenChunkSize = shift;
	
	if (!defined($givenChunkSize)) {
		$givenChunkSize = Slim::Utils::Prefs::get('udpChunkSize') * 10;
	} 
	
	my $chunksize = $givenChunkSize;
	
	my $chunk  = '';

	my $endofsong = undef;

	if ($client->mp3filehandle()) {
	
		if ($client->mp3filehandleIsSocket) {
			# adjust chunksize to lie on metadata boundary (for shoutcast/icecast)
			if ($client->shoutMetaInterval() &&
				($client->shoutMetaPointer() + $chunksize) > $client->shoutMetaInterval()) {
	
				$chunksize = $client->shoutMetaInterval() - $client->shoutMetaPointer();
			}
		} else {
		
			# use the rate to seek to an appropriate place in the file.
			my $rate = rate($client);
			
			# if we're scanning
			if ($rate != 0 && $rate != 1) {
				
				my $lastskip = $client->lastskip();
				
				my $now = $client->songBytes();
				
				my $byterate = Slim::Music::Info::bitratenum(Slim::Player::Playlist::song($client)) / 8;
				
				my $tricksegmentbytes = $byterate * $TRICKSEGMENTLENGTH;
				
				# check to see if we've played tricksgementlength seconds worth of audio
				$::d_source && msg("trick mode rate: $rate:  songbytes: $now lastskip: $lastskip byterate: $byterate\n");
				if (($now - $lastskip) >= $tricksegmentbytes) { 
					# if so, seek to the appropriate place.  (
					# TODO: make this align on frame and sample boundaries as appropriate)
					# TODO: Make the seek go into the next song, as appropriate.
					my $howfar = ($rate -  $TRICKSEGMENTLENGTH) * $byterate;
					my $seekpos = $now + $howfar;
					
					if ($seekpos < 0) {
						# trying to seek past the beginning, let's let opennext do it's job
						$chunksize = 0;
					} else {
						$client->mp3filehandle->seek($seekpos, 0);
						$client->songBytes($client->songBytes() + $howfar);
						$client->lastskip($client->songBytes());
					}
				}
				
				if ($chunksize > $tricksegmentbytes) { $chunksize = $tricksegmentbytes; }
			}

		
			# don't send extraneous ID3 data at the end of the file
			my $size = $client->songtotalbytes();
			my $pos = $client->songBytes();
			
			if ($pos + $chunksize > $size) {
				$chunksize = $size - $pos;
				$::d_source && msg( "Reduced chunksize to $chunksize at end of file ($size - $pos)\n");
				if ($chunksize le 0) { $endofsong = 1; }
			}
			if ($pos > $size) {
				$::d_source && msg( "Trying to read past the end of file, skipping to next file\n");
				$chunksize = 0;
				$endofsong = 1;
			}
		}
		
		if ($chunksize) {
			my $readlen = $client->mp3filehandle()->read($chunk, $chunksize);
			
			if (!defined($readlen)) { 
				if ($! != EWOULDBLOCK) {
					$::d_source && msg("readlen undef $!" . ($! + 0) . "\n"); 
					$endofsong = 1; 
				} else {
					$::d_source && msg("would have blocked, will try again later\n");
					return undef;	
				}	
			}
			
			if (!$client->mp3filehandleIsSocket && $readlen == 0) { 
				$::d_source && msg("readlen undef $!\n");  
				$endofsong = 1;
			}
			
			if ($client->shoutMetaInterval()) {
				$client->shoutMetaPointer($client->shoutMetaPointer() + length($chunk));
		
				# handle instream metadata for shoutcast/icecast
				if ($client->shoutMetaPointer() == $client->shoutMetaInterval()) {
		
					Slim::Web::RemoteStream::readMetaData($client);
					$client->shoutMetaPointer(0);
				}
			}
		}
	} else {
		$::d_source && msg($client->id() . ": No filehandle to read from, returning no chunk.\n");
		$::d_source && bt();
		return undef;
	}

	# if nothing was read from the filehandle, then we're done with it,
	# so open the next filehandle.
	if ($endofsong) {
		$::d_source && msg("end of file or error on socket, opening next song, (song pos: " .
				$client->songBytes() . "(tell says: . " . tell($client->mp3filehandle()). "), totalbytes: " . $client->songtotalbytes() . ")\n");
		if (!openNext($client)) {
			$::d_source && msg("Can't opennext, returning no chunk.");
		}
		
		# we'll have to be called again to get a chunk from the next song.
		return undef;
	}
	
	$::d_source_verbose && msg("read a chunk of " . length($chunk) . " length\n");
	$client->songBytes($client->songBytes + length($chunk));
	
	return \$chunk;
}

sub pauseSynced {
	my $client = shift;
	foreach my $everyclient ($client, Slim::Player::Sync::syncedWith($client)) {
		$everyclient->pause();
	}
}


1;
__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
