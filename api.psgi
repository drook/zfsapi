#!/usr/local/bin/perl

use strict;
use English;
use v5.14;
use Data::UUID;
use IPC::SysV qw(IPC_PRIVATE S_IRUSR S_IWUSR IPC_CREAT IPC_EXCL);
use IPC::Semaphore;

#-----------------------------
my $version = "2.5.3";
my $i;
my $action = "null";
my $snapsource = "null";
my $snapsourcefmt;
my $snapname = "null";
my $bookmarkname = "null";
my $clonesource = "null";
my $clonesourcefmt;
my $clonename = "null";
my $clonenamefmt;
my $victim = "null";
my $victimfmt;
my $snapshot = "null";
my $snapshotfmt;
my $targetname = "null";
my $scsiname = "null";
my $lunid = "null";
my $vendor = "null";
my $device = "null";
my $lun = "null";
my $deviceid = "null";
my $spell;
my $errormessage;
my $warningmessage;
my $infomessage;
my @request;
my @tmp;
my @time;
my $logpath;
my $result;
my $parselogresult;
my @logcontents;
my $line;
my $remotedcip;
my $remotedataset;
my $startsnapshot;
my $endsnapshot;
my $lunidinfo = "null";
my $deviceidinfo = "null";
my $vendorinfo = "null";
# paths
my $ctlconfpath = "/tmp/ctl.conf";
my $sudopath = "/usr/local/bin/sudo";
my $tmppath = "/tmp";
my $loglocation = "/var/log/zfsreplica";
my $diffpath = "/var/www/diff/";
my $zvol = "/dev/zvol/";
# debug: 0 - none, 1 - basic, 2 - extensive
my $debug = 0;
my %children;

my $psgiresult = "";
my $app;
my $env;
my $sem;
my $confsem;

# startup sequence indication
my $juststarted = 1;

# simple stats
my $requests = 0;
#-----------------------------

# compare only version
sub diff_comparsion {
  my ($version_a) = $a =~ /version_(\d+)/;
  my ($version_b) = $b =~ /version_(\d+)/;

  return $version_a <=> $version_b;
}

# args:
# 0 - path for search
# 1 - drive number
sub get_sorted_diffs {
  my $spell = "ls $_[0] | grep -E \"drive_$_[1]_version_[0-9]+\.diff\"";
  return sort diff_comparsion `$spell`;
}

sub getxmlhead(){
    $psgiresult .= "<?xml version=\"1.0\"?>\n";
    $psgiresult .= "<response>\n";
};

sub getxmlfoot(){
    $psgiresult .= "</response>\n";
};

sub dumpall() {
    $i = 0;
    foreach $i(keys(%ENV)) {
	$psgiresult .= "<env>".$i.": ".$ENV{$i}."</env>\n";
    }
}

sub lockCtlOp() {
    $sem->op(0, 0, 0, 0, 1, 0);
}

sub unlockCtlOp() {
    # if we are here, then it must be that the same process aquired the lock
    # so we simply reset it
    $sem->setval(0, 0);
}

sub lockConfOp() {
    $confsem->op(0, 0, 0, 0, 1, 0);
}

sub unlockConfOp() {
    # if we are here, then it must be that the same process aquired the lock
    # so we simply reset it
    $confsem->setval(0, 0);
}

sub parselog() {
    my $openlogresult;
    my $i;

    if ($debug > 0) {
	$psgiresult .= "<debug>about to parse log: ".$logpath."</debug>\n";
    }
    $openlogresult = open(LOG, "<", $logpath);
    if ($openlogresult) {
	undef(@logcontents);
	$i = 0;
	while (!eof(LOG)) {
	    $line = readline(LOG);
	    chomp($line);
	    push @logcontents, $line;
	    $i++;
	}
	if ($debug > 0) {
	    $psgiresult .= "<debug>read ".$i." lines</debug>\n";
	    $psgiresult .= "<debug>log contents array is ".scalar(@logcontents)." elements long</debug>\n";
	}
	close(LOG);
	if ($debug == 0 && scalar(@logcontents) == 0) {
	    unlink($logpath);
	}
	return 0;
    } else {
	$psgiresult .= "<parselog>cannot open log ".$logpath."</parselog>\n";
	return 1;
    }
}

sub getsnapshot() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    if (defined($snapsource) && defined($snapname) && $snapsource ne "null" && $snapname ne "null") {
	$snapsourcefmt = $snapsource;
	$snapsourcefmt =~ s/\//_/g;
	$logpath = $tmppath."/snapshot-".$snapsourcefmt."-".$snapname."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
	$spell = $sudopath." /sbin/zfs snapshot ".$snapsource."@".$snapname." >".$logpath." 2>&1";
	system($spell);
	$parselogresult = parselog();
	if (@logcontents > 0 || $parselogresult != 0) {
	    $errormessage = "log file not empty.";
	    return 1;
	} else {
	    return 0;
	}
    } else {
	$errormessage = "missing snapshot source or snapshot name.";
	return 1;
    }
}

sub getbookmark() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    my $source;
    my @tmp;

    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    if (defined($snapsource) && defined($bookmarkname) && $snapsource ne "null" && $bookmarkname ne "null") {
	@tmp = split(/@/, $snapsource);
	$source = $tmp[0];
	$snapsourcefmt = $snapsource;
	$snapsourcefmt =~ s/\//_/g;
	$logpath = $tmppath."/bookmark-".$snapsourcefmt."-".$bookmarkname."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
	$spell = $sudopath." /sbin/zfs bookmark ".$snapsource." ".$source."#".$bookmarkname." >".$logpath." 2>&1";
	system($spell);
	$parselogresult = parselog();
	if (@logcontents > 0 || $parselogresult != 0) {
	    $errormessage = "log file not empty.";
	    return 1;
	} else {
	    return 0;
	}
    } else {
	$errormessage = "missing snapshot source or bookmark name.";
	return 1;
    }
}

sub getclone() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    if (defined($clonesource) && defined($clonename) && $clonesource ne "null" && $clonename ne "null") {
	$clonesourcefmt = $clonesource;
	$clonesourcefmt =~ s/\//_/g;
	$clonenamefmt =~ s/\//_/g;
	$logpath = $tmppath."/clone-".$clonesourcefmt."-".$clonenamefmt."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
	$spell = $sudopath." /sbin/zfs clone ".$clonesource." ".$clonename." >".$logpath." 2>&1";
	system($spell);
	$parselogresult = parselog();
	if (@logcontents > 0 || $parselogresult != 0) {
	    $errormessage = "log file not empty.";
	    return 1;
	} else {
	    return 0;
	}
    } else {
	$errormessage = "missing snapshot source or snapshot name.";
	return 1;
    }
}

sub getipcstats() {
    sub getProperTime {
	my $unixtime = shift;

	#($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
	@time = localtime($unixtime);
	$time[4]++;
	$time[5] += 1900;

	return $time[3]."/".$time[4]."/".$time[5]." ".$time[2].":".$time[1].":".$time[0];
    }
    my $buf;
    my $value;
    my $otime;
    my $ctime;

    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    $value = $sem -> getval(0);
    $buf = $sem -> stat(0);
    $ctime = $buf -> [5];
    $otime = $buf -> [6];

    $psgiresult .= "<mainsemaphore><value>".$value."</value><ctime>".getProperTime($ctime)."</ctime><otime>".getProperTime($otime)."</otime></mainsemaphore>\n";

    $value = $confsem -> getval(0);
    $buf = $confsem -> stat(0);
    $ctime = $buf -> [5];
    $otime = $buf -> [6];

    $psgiresult .= "<confsemaphore><value>".$value."</value><ctime>".getProperTime($ctime)."</ctime><otime>".getProperTime($otime)."</otime></confsemaphore>\n";

    return 0;
}

sub getstatus() {
    my $ug;
    my $uuid;

    $ug = Data::UUID -> new;
    $uuid = $ug -> create_str();
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    $logpath = $tmppath."/status-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log.".$uuid;
    $spell = $sudopath." /sbin/zfs list -t all >".$logpath." 2>&1";
    system($spell);
    $parselogresult = parselog();
    if ($parselogresult == 0) {
	return 0;
    } else {
	return 1;
    }
}

sub getreload() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    $logpath = $tmppath."/reload-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
    $spell = $sudopath." /usr/sbin/service ctld reload >".$logpath." 2>&1";
    system($spell);
    $parselogresult = parselog();
    if ($parselogresult == 0) {
	return 0;
    } else {
	return 1;
    }
}

sub formatspell {
    my $spellfmt;

    $spellfmt = $_[0];

    $spellfmt =~ s/\&/\&amp\;/g;
    $spellfmt =~ s/\>/\&gt\;/g;
    $spellfmt =~ s/\</\&lt\;/g;

    return $spellfmt;
}

sub getrelease() {
    my $ug;
    my $uuid;
    my $ctladmlogpath;
    my @temp;
    my $ctladmlines = 0;
    my $devicefound = 0;

    my $blockdev;
    my $vdev;
    my $lunname;
    my $victimshortname;

    if ($debug > 1) {
        $psgiresult .= "<debug>got inside getrelase().</debug>\n";
    }

    if (defined($victim) && $victim ne "null") {
	if ($debug > 1) {
	    $psgiresult .= "<debug>victim name defined and is not null.</debug>\n";
	}
    $ug = Data::UUID -> new;
    $uuid = $ug -> create_str();
    @temp = split('/',$victim);
    $victimshortname = $temp[scalar(@temp) - 1];
	if ($debug > 1) {
	    $psgiresult .= "<debug>victim short name: ".$victimshortname.".</debug>\n";
	}

    $ctladmlogpath = "/tmp/ctladm.log.".$uuid;
	if ($debug > 1) {
	    $psgiresult .= "<debug>ctladm log path: ".$ctladmlogpath.".</debug>\n";
	}
    $spell = $sudopath." /usr/sbin/ctladm devlist -v > ".$ctladmlogpath." 2>&1";
	if ($debug > 1) {
	    $psgiresult .= "<debug>calling spell.</debug>\n";
	}
    lockCtlOp();
    system($spell);
    unlockCtlOp();
    open(CTLADMLOG, "<", $ctladmlogpath) or return 1;
    while (!eof(CTLADMLOG) && $devicefound == 0) {
        $line = readline(*CTLADMLOG);
        chomp($line);

        if ($line =~ /^[\s\t]*\d+ block/) {
            $line =~ s/^\s+//;
            @temp = split(/\s+/, $line);
            $blockdev = $temp[0];
        } else {
            if ($line =~ /^[\s\t]*file=/) {
                @temp = split(/=/, $line);
                $vdev = $temp[1];
                    if ($vdev eq '/dev/zvol/'.$victim ) {
                        # we found our victim
		                if ($debug > 1) {
		                    $psgiresult .= "<debug>found our victim using file backend path.</debug>\n";
		                }
                        $devicefound = 1;
                        @time = localtime(time());
                        $time[4]++;
                        $time[5] += 1900;
                        $victimfmt = $victim;
                        $victimfmt =~ s/\//_/g;

                        $logpath = $tmppath."/release-".$victimfmt."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
                        $spell = $sudopath." /usr/sbin/ctladm remove -b block -l ".$blockdev." >".$logpath." 2>&1";

                        if ($debug > 0) {
                            $psgiresult .= "<debug>".formatspell($spell)."</debug>\n";
                        }
                        # locking the LUN
                        lockCtlOp();
                        system($spell);
                        # unlocking the LUN
                        unlockCtlOp();
                        if ($debug > 1) {
                            $psgiresult .= "<debug>calling parselog ()</debug>\n";
                        }
                        $parselogresult = parselog();
                    }
                }
            }
            $ctladmlines++;
        }
        close(CTLADMLOG);
        if ($devicefound == 0) {
            # we didn't find our device, lets retry with lun name
            open(CTLADMLOG, "<", $ctladmlogpath) or return 1;
            while (!eof(CTLADMLOG) && $devicefound == 0) {
                $line = readline(*CTLADMLOG);
                chomp($line);

                if ($line =~ /^[\s\t]*\d+ block/) {
                    $line =~ s/^\s+//;
                    @temp = split(/\s+/, $line);
                    $blockdev = $temp[0];
                    $lunname = $temp[5];

                    if ($lunname eq $victimshortname ) {
                        # we found our victim
		        if ($debug > 1) {
		            $psgiresult .= "<debug>found our victim using shortname.</debug>\n";
		        }
                        $devicefound = 1;
                        @time = localtime(time());
                        $time[4]++;
                        $time[5] += 1900;
                        $victimfmt = $victim;
                        $victimfmt =~ s/\//_/g;

                        $logpath = $tmppath."/release-".$victimfmt."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
                        $spell = $sudopath." /usr/sbin/ctladm remove -b block -l ".$blockdev." >".$logpath." 2>&1";

                        if ($debug > 0) {
                            $psgiresult .= "<debug>".formatspell($spell)."</debug>\n";
                        }
                        # locking the LUN
                        lockCtlOp();
                        system($spell);
                        # unlocking the LUN
                        unlockCtlOp();
                        if ($debug > 1) {
                            $psgiresult .= "<debug>calling parselog ()</debug>\n";
                        }
                        $parselogresult = parselog();
                    }
                }
                $ctladmlines++;
            }
            close(CTLADMLOG);
        }
        if ($debug == 0 && @logcontents == 1) {
            unlink($logpath);
            unlink($ctladmlogpath);
        }
        if ($ctladmlines <= 1) {
            $errormessage = "ctladm log is empty, check sudo permissions.";
            return 1;
        }
        if ($devicefound == 0) {
            $errormessage = "didn't find device to release.";
            return 1;
        }
        if (@logcontents == 1  && $parselogresult == 0 && $logcontents[0] =~ /LUN \d+ removed successfully/ && $devicefound == 1) {
            return 0;
        } else {
            if ($debug > 0) {
                $psgiresult .= "<debug>ctladm log lines parsed: ".$ctladmlines."</debug>\n";
                $psgiresult .= "<debug>device found: ".$devicefound."</debug>\n";
                $psgiresult .= "<debug>parselogresult: ".$parselogresult."</debug>\n";
                $psgiresult .= "<debug>log content lines: ".scalar(@logcontents)."</debug>\n";
                if (@logcontents > 0) {
                    $psgiresult .= "<debug>first log line: ".$logcontents[0]."</debug>\n";
                }
            }
            $errormessage = "log file tells me something got wrong (or cannot open log).";
            return 1;
        }
    } else {
        $errormessage = "missing entity name to release.";
        return 1;
    }
}

sub gettargetconfig() {
    if (not defined($targetname) || $targetname == "null") {
        $errormessage = "Missing target name";
        return;
    }
    my $target = $targetname;
    my $file = '/etc/ctl.conf';

    my @target_param_keys = (
        "initiator-portal", 
        "portal-group", 
        "auth-type"
        );
    my @lun_param_keys = (
        "ctl-lun", 
        "device-id", 
        "path", 
        "serial", 
        "vendor"
        );
    my %target_params = ("targetname" => "$target");
    my %lun_params;

    open F, "<", $file or (
        $errormessage = "could not open $file : $!"
        and return);
    my $old_delim = $/;
    $/ = undef;
    my $config = <F>;
    close F;
    $/ = $old_delim;

    # remove commented lines
    $config =~ s/#.*?\n//sg;

    # find our target record
    if($config !~ /target\s+\Q$target\E\s*({.*?)\s*(?:target|\Z)/s) {
        $errormessage = "Target $target not found.";
        return;
    }
    $1 =~ /\{(.*)\}/s;
    $config = $1;

    # look for target parameters
    foreach (@target_param_keys) {
        if($config =~ /\Q$_\E\s+(\S+)/s) {
            $target_params{$_} = $1;
        }
    }

    # look for lun 0 parameters
    $config =~ /lun\s+0\s*\{(.*?)\}/s;
    my $lun0_config = $1;
    foreach (@lun_param_keys) {
        if($lun0_config =~ /\Q$_\E\s+(\S+)/s) {
            $target_params{$_} = $1;
        }
    }

    return %target_params;
}

sub gettargetinfo() {
    my $ug;
    my $uuid;
    my $ctladmlogpath;
    my @temp;
    my $ctladmlines = 0;
    my $devicefound = 0;

    my $blockdev = "null";
    my $device;
    my $ctldname;

    if (defined($targetname) && $targetname ne "null") {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();

	$ctladmlogpath = "/tmp/ctladm.log.".$uuid;
	$spell = $sudopath." /usr/sbin/ctladm devlist -v > ".$ctladmlogpath." 2>&1";
	lockCtlOp();
	system($spell);
	unlockCtlOp();
	open(CTLADMLOG, "<", $ctladmlogpath) or return 1;
	while (!eof(CTLADMLOG) && $devicefound == 0) {
	    $line = readline(*CTLADMLOG);
	    chomp($line);

	    if ($line =~ /^[\s\t]*\d+ block/) {
		@temp = split(/ +/, $line);
		$blockdev = $temp[0];
		$lunidinfo = $temp[1];
		$deviceidinfo = $temp[7];
	    } else {
		if ($line =~ /^[\s\t]*ctld_name=/) {
        	    @temp = split(/=/, $line);
        	    $ctldname = $temp[1];

        	    if ($ctldname =~ /$targetname,lun,\d+/) {
        		# we found our target
        		$devicefound = 1;
        	    } else {
        	    }
		} else {
        	    if ($line =~ /^[\s\t]*file=\/dev\/zvol\/.+/) {
        		@temp = split(/=/, $line);
        		$device = @temp[1];
        	    } else { 
            		if ($line =~ /^[\s\t]*vendor=/) {
                	    @temp = split(/=/, $line);
                	    $vendorinfo = @temp[1];
            		}
        	    }
		}
	    }
	    $ctladmlines++;
	}
	close(CTLADMLOG);
	if ($debug == 0) {
	    unlink($ctladmlogpath);
	}

	if ($devicefound != 0) {
	    return $device;
	}

	if ($devicefound == 0) {
	    $errormessage = "didn't find requested the device this target is serving.";
	    return -1;
	}
	if ($ctladmlines <= 1) {
	    $errormessage = "ctladm log is empty, check sudo permissions.";
	    return -1;
	}
    } else {
	$errormessage = "missing target name to get info about.";
	return -1;
    }
}

sub destroyentity() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    if (defined($victim)) {
	$victimfmt = $victim;
	$victimfmt =~ s/\//_/g;
	$logpath = $tmppath."/destroy-".$victimfmt."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
	$spell = $sudopath." /sbin/zfs destroy ".$victim." >".$logpath." 2>&1";
	system($spell);
	$parselogresult = parselog();
	if (@logcontents > 0 || $parselogresult != 0) {
	    $errormessage = "log file not empty.";
	    return 1;
	} else {
	    return 0;
	}
    } else {
	$errormessage = "missing entity name to destroy.";
	return 1;
    }
}

sub getrollback() {
    #($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    @time = localtime(time());
    $time[4]++;
    $time[5] += 1900;
    if (defined($snapshot)) {
	$snapshotfmt = $snapshot;
	$snapshotfmt =~ s/\//_/g;
	$logpath = $tmppath."/rollback-".$snapshotfmt."-".$time[5]."-".$time[4]."-".$time[3]."-".$time[2]."-".$time[1]."-".$time[0].".log";
	$spell = $sudopath." /sbin/zfs rollback ".$snapshot." >".$logpath." 2>&1";
	system($spell);
	$parselogresult = parselog();
	if ($debug > 0) {
	    $psgiresult .= "<debug>log contents array is ".scalar(@logcontents)." elements long</debug>\n";
	}
	if (scalar(@logcontents) > 0 || $parselogresult != 0) {
	    $errormessage = $logcontents[0];
	    return 1;
	} else {
	    return 0;
	}
    } else {
	$errormessage = "missing snapshot name to rollback to.";
	return 1;
    }
}

sub enabletarget() {
    my $uuid;
    my $ug;
    my $ctlconfpath;
    my $line;
    my $bracketcount = 0;
    my $targetfound = 0;

    if (defined($targetname)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$ctlconfpath = "/tmp/ctl.conf.".$uuid;
	$spell = $sudopath." /bin/cp /etc/ctl.conf ".$ctlconfpath;
	system($spell);
	$spell = $sudopath." /bin/chmod 644 ".$ctlconfpath;
	system($spell);
	open(CTLCONF, "<", $ctlconfpath) or return 1;
	open(CTLCONFNEW, ">", $ctlconfpath.".new") or return 1;
	while (!eof(CTLCONF)) {
	    $line = readline(*CTLCONF);
	    chomp($line);
	    if ($line =~ /^[\s\t]*\#target $targetname[\s\t]*\{/) {
		$bracketcount++;
		$targetfound = 1;
		$line = substr($line, 1)
	    } else {
		if ($line =~ /^[\s\t]*target $targetname[\s\t]*\{/) {
		    $errormessage = "target is enabled already.";
		}
		if ($bracketcount > 0) {
		    if ($line =~ /.*\}/) {
			$bracketcount--;
		    }
		    if ($line =~ /.*\{/) {
        		$bracketcount++;
        	    }
        	    $line = substr($line, 1)
		}
	    }
	    print CTLCONFNEW $line, "\n";
	}
	close(CTLCONF);
	close(CTLCONFNEW);
	$spell = $sudopath." /bin/chmod 600 ".$ctlconfpath.".new";
	system($spell);
	$spell = $sudopath." /bin/mv ".$ctlconfpath.".new /etc/ctl.conf";
	lockConfOp();
	system($spell);
	unlockConfOp();
	if ($debug > 0) {
	    $psgiresult .= "<debug>returning 0</debug>\n";
	}
	$spell = $sudopath." /usr/sbin/chown zfsreplica:www ".$ctlconfpath;
	system($spell);
	if ($debug == 0) {
	    unlink($ctlconfpath);
	}
	if ($targetfound > 0) {
	    return 0;
	} else {
	    return 1;
	}
    } else {
	return 1;
    }
}

sub disabletarget() {
    my $uuid;
    my $ug;
    my $ctlconfpath;
    my $line;
    my $bracketcount = 0;
    my $targetfound = 0;
    my $openstatus = 0;

    if (defined($targetname)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$ctlconfpath = "/tmp/ctl.conf.".$uuid;
	$spell = $sudopath." /bin/cp /etc/ctl.conf ".$ctlconfpath;
	system($spell);
	$spell = $sudopath." /bin/chmod 644 ".$ctlconfpath;
	system($spell);
	$openstatus = open(CTLCONF, "<", $ctlconfpath);
	if ($openstatus == 0) {
	    $errormessage = "cannot open ".$ctlconfpath." for reading.";
	return 1;
	}
	open(CTLCONFNEW, ">", $ctlconfpath.".new") or return 1;
	while (!eof(CTLCONF)) {
	$line = readline(*CTLCONF);
	    chomp($line);
	    if ($line =~ /^[\s\t]*target $targetname[\s\t]*\{/) {
		$bracketcount++;
		$targetfound = 1;
		#$psgiresult .= "<debug>BRACKETCOUNT UP: ".$bracketcount."</debug>\n";
		#$psgiresult .= "<debug># ".$line."</debug>\n";
		print CTLCONFNEW "#", $line, "\n";
	    } else {
		if ($line =~ /^\#[\s\t]*target $targetname[\s\t]*\{/) {
        	    $errormessage = "target is disabled already.";
        	    $targetfound = 1;
		}
		if ($bracketcount > 0) {
        	    if ($line =~ /.*\}/) {
        		$bracketcount--;
        		#$psgiresult .= "<debug>BRACKETCOUNT DOWN: ".$bracketcount."</debug>\n";
        	    }
        	    if ($line =~ /.*\{/) {
        		$bracketcount++;
        		#$psgiresult .= "<debug>BRACKETCOUNT UP: ".$bracketcount."</debug>\n";
        	    }
        	    #$psgiresult .= "<debug># ".$line."</debug>\n";
        	    print CTLCONFNEW "#", $line, "\n";
		} else {
        	    #$psgiresult .= "<debug>NOMOD ".$line."</debug>\n";
        	    print CTLCONFNEW $line, "\n";
		}
	    }
	}
	close(CTLCONF);
	close(CTLCONFNEW);
	$spell = $sudopath." /bin/chmod 600 ".$ctlconfpath.".new";
	system($spell);
	$spell = $sudopath." /bin/mv ".$ctlconfpath.".new /etc/ctl.conf";
	lockConfOp();
	system($spell);
	unlockConfOp();
	$spell = $sudopath." /usr/sbin/chown zfsreplica:www ".$ctlconfpath;
	system($spell);
	if ($debug == 0) {
	    unlink($ctlconfpath);
	}
	if ($targetfound > 0) {
	    if ($debug > 0) {
		$psgiresult .= "<debug>returning 0</debug>\n";
	    }
	    return 0;
	} else {
	    $errormessage = "target not found.";
	    return 1;
	}
    } else {
	$errormessage = "targetname not defined.";
	return 1;
    }
}

sub mounttarget() {
    my $uuid;
    my $ug;
    my $ctlconfpath;
    my $line;
    my $bracketcount = 0;
    my $targetfound = 0;
    my $lunfound = 0;
    my $targetmodified = 0;

    if (defined($targetname) && defined($device)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$ctlconfpath = "/tmp/ctl.conf.".$uuid;
	$spell = $sudopath." /bin/cp /etc/ctl.conf ".$ctlconfpath;
	system($spell);
	$spell = $sudopath." /bin/chmod 644 ".$ctlconfpath;
	system($spell);
	open(CTLCONF, "<", $ctlconfpath) or return 1;
	open(CTLCONFNEW, ">", $ctlconfpath.".new") or return 1;
	while (!eof(CTLCONF)) {
	    $line = readline(*CTLCONF);
	    chomp($line);
	    if ($line =~ /^[\s\t]*[\#]*target $targetname[\s\t]*\{/) {
		$bracketcount++;
		$targetfound = 1;
	    } else {
		if ($targetfound == 1 && $bracketcount == 2 && $lunfound ==1 && $line =~ /[\s\t]*path /) {
        	    @tmp = split(/path/, $line);
        	    $line = $tmp[0]."path ".$device;
        	    $targetmodified = 1;
		} else {
        	    if ($bracketcount > 0) {
        		if ($line =~ /.*\}/) {
            		    $bracketcount--;
            		    if ($lunfound == 1) {
            			$lunfound = 0;
            		    }
            		    # bracketcount was > 0 when entered, but then descreased to 0 -> means we're off the target
            		    if ($bracketcount == 0) {
            			$targetfound = 0;
            		    }
        		}
        		if ($line =~ /.*\{/) {
            		    $bracketcount++;
            		    if ($line =~ /lun $lun/) {
            			$lunfound = 1;
            		    }
        		}
        		} else {
        	    }
		}
	    }
	    print CTLCONFNEW $line, "\n";
	}
	close(CTLCONF);
	close(CTLCONFNEW);
	$spell = $sudopath." /bin/chmod 600 ".$ctlconfpath.".new";
	system($spell);
	$spell = $sudopath." /bin/mv ".$ctlconfpath.".new /etc/ctl.conf";
	lockConfOp();
	system($spell);
	unlockConfOp();
	$spell = $sudopath." /usr/sbin/chown zfsreplica:www ".$ctlconfpath;
	system($spell);
	if ($debug == 0) {
	    unlink($ctlconfpath);
	}
	if ($targetmodified > 0) {
	    if ($debug > 0) {
		$psgiresult .= "<debug>returning 0</debug>\n";
	    }
	    return 0;
	} else {
	    if ($debug > 0) {
		$psgiresult .= "<debug>returning 1</debug>\n";
	    }
	    return 1;
	}
    } else {
	return 1;
    }
}

sub handleresult() {
    if ($result == 0) {
        $psgiresult .= "<status>success</status>\n";
    } else {
        $psgiresult .= "<status>error</status>\n";
	$psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
	$psgiresult .= "<log>\n";
	$i = 0;
	while ($i < @logcontents) {
	    $psgiresult .= "<entry>".$logcontents[$i]."</entry>\n";
	    $i++
	}
	$psgiresult .= "</log>\n";
    }
}

sub handlestatus {
    if ($result == 0) {
        $psgiresult .= "<status>success</status>\n";
    } else {
        $psgiresult .= "<status>error</status>\n";
	$psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
    }
    $psgiresult .= "<log>\n";
    $i = 0;
    while ($i < @logcontents) {
	if ($logcontents[$i] =~ /^NAME/) {
	} else {
	    #$psgiresult .= "<raw>".$logcontents[$i]."</raw>";
	    @tmp = split(/[\s\t]+/, $logcontents[$i]);
	    $psgiresult .= "<zfsentity>\n";
	    $psgiresult .= "<name>".$tmp[0]."</name>\n";
	    $psgiresult .= "<used>".$tmp[1]."</used>\n";
	    $psgiresult .= "<avail>".$tmp[2]."</avail>\n";
	    $psgiresult .= "<refer>".$tmp[3]."</refer>\n";
	    $psgiresult .= "<mountpoint>".$tmp[4]."</mountpoint>\n";
	    $psgiresult .= "</zfsentity>\n";
	}
        $i++
    }
    $psgiresult .= "</log>\n";
}

sub getsendingdetails() {
    # return the number of sending processes or -1 if error occured
    my $ug;
    my $uuid;
    my $linecount = 0;
    my $lognamestart;
    my $spell;
    my $rs;

    my $estimated;
    my $sent;
    my @tmp;
    my $sendlogpath;
    my $spellfmt;

    if (defined($remotedcip) && defined($startsnapshot) && defined($endsnapshot)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$logpath = "/tmp/zfs-send-details-".$uuid.".log";

	$spell = "ps awwwwx | grep zfs\\ send | grep @".$startsnapshot." | grep @".$endsnapshot." | egrep -v 'sudo|grep' | wc -l | tr -d ' ' >".$logpath;
	if ($debug > 0) {
	    $spellfmt = $spell;
	    $spellfmt =~ s/>/&gt;/g;
	    $psgiresult .= "<debug><spell>".$spell."</spell></debug>\n"
	}
	system($spell);
	open(LOG, "<".$logpath);
	while (!eof(LOG)) {
	    $line = readline(LOG);
	    chomp($line);
	    $linecount++;
	}
	close(LOG);
	if ($debug == 0) {
	    unlink($logpath);
	}

	if ($linecount > 1) {
	    $errormessage = "log lines number is greater than one.";
	    return -1;
	} else {
	    $psgiresult .= "<active>".$line."</active>\n";
	    $uuid = $ug -> create_str();
	    $logpath = "/tmp/zfs-send-details-ps-".$uuid.".log";
	    $lognamestart = "zfs-send-".$remotedcip;
	    $spell = "ls -l ".$loglocation." | grep ".$lognamestart." | grep @".$startsnapshot." | grep @".$endsnapshot." | awk '{print $9}' >".$logpath;
	    if ($debug > 1) {
		$psgiresult .= "<debug><sendlogsearchspell>".$spell."</sendlogsearchspell></debug>\n"
	    }
	    system($spell);

	    $rs = open(SPELLLOG, "<".$logpath);
	    if ($rs > 0) {
		$linecount = 0;
		while (!eof(SPELLLOG)) {
        	    $line = readline(SPELLLOG);
        	    chomp($line);
        	    if ($debug > 1) {
        		$psgiresult .= "<debug><rawline>".$line."</rawline></debug>\n"
        	    }
        	    chomp($line);
        	    @tmp = split(/[\s\t]+/, $line);
        	    $sendlogpath = $tmp[8];
        	    $linecount++;
		}
		close(SPELLLOG);
		if ($debug == 0) {
        	    unlink($logpath);
		}
	    } else {
		$errormessage = "cannot open file for reading: ".$logpath;
		return -1;
	    }

	    if ($debug > 0) {
		$psgiresult .= "<debug><sendlogpath>".$loglocation."/".$sendlogpath."</sendlogpath></debug>\n"
	    }

	    if ($sendlogpath ne "") {
		$rs = open(SENDLOG, "<".$loglocation."/".$sendlogpath);
		if ($rs > 0) {
        	    while (!eof(SENDLOG)) {
        		$line = readline(SENDLOG);
        		chomp($line);
        		if ($debug > 1) {
        		    $psgiresult .= "<debug><rawline>".$line."</rawline></debug>"
        		}
        		if ($line =~ /total estimated size is/) {
        		    @tmp = split(/[\s\t]+/, $line);
        		    $estimated = $tmp[4];
			} else {
        		    if ($line =~ /\d+:\d+:\d+/) {
        			@tmp = split(/[\s\t]+/, $line);
        			$sent = $tmp[1];
        		    }
        		}
        		#
        		# ERROR HANDLING
        		#

        		# cannot receive incremental stream: destination data/testrep has been modified
        		# since most recent snapshot
        		if ($line =~ /cannot receive incremental stream: destination .+ has been modified/) {
        		    return "<senderror>cannot receive incremental stream: destination has been modified</senderror>";
        		}
        		# warning: cannot send 'data/testrep@ver1008_18': signal received
        		if ($line =~ /cannot send .+: signal received/) {
        		    return "<senderror>cannot send: signal received</senderror>";
        		}
        	    }
        	    close(SENDLOG);

        	    # do the final data
        	    return "<details>\n<totalestimated>".$estimated."</totalestimated>\n<alreadysent>".$sent."</alreadysent>\n</details>\n";
		} else {
        	    $errormessage = "cannot open zfs send logfile for reading: ".$sendlogpath;
        	    return -1;
		}
	    } else {
		$errormessage = "cannot find send log.";
		return -1;
	    }
	}
    } else {
	if (defined($remotedcip)) {
	    if (defined($endsnapshot)) {
		$errormessage = "start snapshot name not supplied.";
	    } else {
		$errormessage = "end snapshot name not supplied.";
	    }
	} else {
	    $errormessage = "remote DC ip not supplied.";
	}
	return -1;
    }
}

sub getsendingstatus() {
    # return the number of sending processes or -1 if error occured
    my $ug;
    my $uuid;
    my $linecount = 0;

    if (defined($remotedcip)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$logpath = "/tmp/zfs-send-list-local.log.".$uuid;

	$spell = "ps awwwx | grep zfs\\ receive | grep ".$remotedcip." | grep -v grep | wc -l | tr -d ' ' >".$logpath;
	system($spell);
	open(LOG, "<".$logpath);
	while (!eof(LOG)) {
	    $line = readline(LOG);
	    chomp($line);
	    $linecount++;
	}
	close(LOG);
	if ($debug == 0) {
	    unlink($logpath);
	}
	if ($linecount > 1) {
	    $errormessage = "log lines number is greater than one.";
	    return -1;
	} else {
	    return $line;
	}
    } else {
	$errormessage = "remote DC ip not supplied.";
	return -1;
    }
}

sub getreceivingstatus() {
    # return the number of sending processes or -1 if error occured
    my $ug;
    my $uuid;
    my $linecount = 0;

    $ug = Data::UUID -> new;
    $uuid = $ug -> create_str();
    $logpath = "/tmp/zfs-send-list-local.log.".$uuid;

    $spell = "ps ax | grep zfs\\ receive | egrep -v 'grep|ssh' | wc -l | tr -d ' ' >".$logpath;
    if ($debug > 0) {
	$psgiresult .= "<debug>spell: ".$spell."</debug>"
    }
    system($spell);
    open(LOG, "<".$logpath);
    while (!eof(LOG)) {
        $line = readline(LOG);
        chomp($line);
        $linecount++;
    }
    close(LOG);
    if ($debug == 0) {
	unlink($logpath);
    }
    if ($linecount > 1) {
        $errormessage = "log lines number is greater than one.";
        return -1;
    } else {
        return $line;
    }
}

sub senddelta() {
    #remoteip="213.152.134.1"
    #dataset2replicate="reference"
    #localtank="data"
    #remotetank="data"
    #dcid="ver2"
    #alreadysending="no"

    my $logpath;
    my $ug;
    my $uuid;
    my $firstsnapexists = 0;
    my $secondsnapexists = 0;
    my $line;
    my @tmp;
    my $remotestartsnapshot;
    my $remoteendsnapshot;
    my $elementcount;
    my $startsnapshotescaped;
    my $endsnapshotescaped;
    my $startedat;
    my $formattedspell;
    my $pid;

    $startedat = time();
    if (defined($remotedcip) && defined($remotedataset) && defined($startsnapshot) && defined($endsnapshot)) {
	$ug = Data::UUID -> new;
	$uuid = $ug -> create_str();
	$logpath = "/tmp/zfs-list-local.log.".$uuid;
	
	# make sure local snapshots exist
	$spell = "zfs list -t snapshot | egrep -v 'NAME +USED' >".$logpath;
	system($spell);
	open(LOG, "<".$logpath);
	if ($debug > 1) {
		$psgiresult .= "<debug>\n";
	}
	while (!eof(LOG) && ($firstsnapexists == 0 || $secondsnapexists == 0)) {
	    if ($debug > 1) {
	        $psgiresult .= "<firstsnapexists>".$firstsnapexists."</firstsnapexists>\n";
	        $psgiresult .= "<secondsnapexists>".$secondsnapexists."</secondsnapexists>\n";
	    }
	    $line = readline(LOG);
	    chomp($line);
	    @tmp = split(/[\s\t]+/, $line);
	    if ($debug > 1) {
		$psgiresult .= "<line>".$tmp[0]."</line>\n";
	    }
	    if ($tmp[0] eq $startsnapshot) {
		if ($debug > 1) {
		    $psgiresult .= "<startercondition>matched</startercondition>\n";
		}
		$firstsnapexists = 1;
	    } else {
		if ($debug > 1) {
		    $psgiresult .= "<startercondition>not matched</startercondition>\n";
		}
		if ($debug > 1) {
		    $psgiresult .= "<comparsion>".$tmp[0]." doesn't match the ".$startsnapshot."</comparsion>\n";
		}
		if ($tmp[0] eq $endsnapshot) {
		    if ($debug > 1) {
			$psgiresult .= "<endcondition>matched</endcondition>\n";
		    }
		    $secondsnapexists = 1;
		} else {
		    if ($debug > 1) {
			$psgiresult .= "<endcondition>not matched</endcondition>\n";
			$psgiresult .= "<comparsion>".$tmp[0]." doesn't match the ".$endsnapshot."</comparsion>\n";
		    }
		}
	    }
	}
	close(LOG);
	if ($debug == 0) {
	    unlink($logpath);
	}
	if ($debug > 1) {
	    $psgiresult .= "</debug>\n";
	}

	if ($debug > 0) {
	    $psgiresult .= "<debug>\n";
	    $psgiresult .= "<firstsnapexists>".$firstsnapexists."</firstsnapexists>\n";
	    $psgiresult .= "<secondsnapexists>".$secondsnapexists."</secondsnapexists>\n";
	    $psgiresult .= "</debug>\n";
	}
	# if they don't exist - then bail out
	if ($firstsnapexists == 0 || $secondsnapexists == 0) {
	    if ($firstsnapexists == 0) {
		$errormessage = "start snapshot doesn't exist on local side.";
	    } else {
		$errormessage = "end snapshot doesn't exist on local side.";
	    }
	    return 1;
	}

	# make sure the zfs snapshot the diff is starting with exists on the remote side and the end doesn't
	@tmp = split(/[\/@]/, $startsnapshot);
	$elementcount = scalar(@tmp);
	$remotestartsnapshot = $remotedataset."/".$tmp[$elementcount - 2]."@".$tmp[$elementcount - 1];
	@tmp = split(/[\/@]/, $endsnapshot);
	$elementcount = scalar(@tmp);
	$remoteendsnapshot = $remotedataset."/".$tmp[$elementcount - 2]."@".$tmp[$elementcount - 1];
	if ($debug > 0) {
	    $psgiresult .= "<debug>\n";
	    $psgiresult .= "<remotestartsnapshot>".$remotestartsnapshot."</remotestartsnapshot>\n";
	    $psgiresult .= "<remoteendsnapshot>".$remoteendsnapshot."</remoteendsnapshot>\n";
	    $psgiresult .= "</debug>\n";
	}
	$logpath = "/tmp/zfs-list-".$remotedcip.".log.".$uuid;
	$spell = "ssh ".$remotedcip." zfs list -t snapshot | egrep -v 'NAME +USED' >".$logpath;
	if ($debug > 0) {
	    $psgiresult .= "<debug>\n";
	    $formattedspell = $spell;
	    $formattedspell =~ s/&/&amp;/g;
	    $psgiresult .= "<spell>".$formattedspell."</spell>";
	    $psgiresult .= "</debug>\n";
	}
	system($spell);
	$firstsnapexists = 0;
	$secondsnapexists = 0;
	if ($debug > 1) {
	    $psgiresult .= "<debug>\n";
	}
	open(LOG, "<".$logpath);
	while (!eof(LOG) && ($firstsnapexists == 0 || $secondsnapexists == 0)) {
	    $line = readline(LOG);
	    chomp($line);
	    @tmp = split(/[\s\t]+/, $line);
	    if ($debug > 1) {
		$psgiresult .= "<line>".$tmp[0]."</line>\n";
	    }
	    if ($tmp[0] eq $remotestartsnapshot) {
		if ($debug > 1) {
		    $psgiresult .= "<startercondition>matched</startercondition>\n";
		}
		$firstsnapexists = 1;
	    } else {
		if ($debug > 1) {
		    $psgiresult .= "<startercondition>not matched</startercondition>\n";
		}
		if ($tmp[0] eq $remoteendsnapshot) {
		    if ($debug > 1) {
			$psgiresult .= "<endcondition>matched</endcondition>\n";
		    }
		    $secondsnapexists = 1;
		}
	    }
	}
	close(LOG);
	if ($debug == 0) {
	    unlink($logpath);
	}
	if ($debug > 1) {
		$psgiresult .= "</debug>\n";
	}
	if ($debug > 0) {
	    $psgiresult .= "<debug>pre-send checks took ".(time() - $startedat)." seconds</debug>\n";
	}

	# if first snapshot doesn't exist on the remote - then bail out
	if ($firstsnapexists == 0) {
	    $errormessage = "start snapshot doesn't exist on the remote side.";
	    return 1;
	}

	if ($secondsnapexists == 1) {
	    $errormessage = "end snapshot already exists on the remote side.";
	    return 1;
	}

	# now check if we're not sending it now
	if (getsendingstatus() > 0) {
	    $errormessage = "seems like we're already sending.";
	    return 1;
	}

	# now send it
	$startsnapshotescaped = $startsnapshot;
	$startsnapshotescaped =~ s/\//--/g;
	$endsnapshotescaped = $endsnapshot;
	$endsnapshotescaped =~ s/\//--/g;
	$logpath = $loglocation."/zfs-send-".$remotedcip."-".$startsnapshotescaped."-".$endsnapshotescaped.".log";
	if ($debug > 0) {
	    $psgiresult .= "<debug>\n";
	    $psgiresult .= "<firstsnapexistsonremote>".$firstsnapexists."</firstsnapexistsonremote>\n";
	    $psgiresult .= "<secondsnapexistsonremote>".$secondsnapexists."</secondsnapexistsonremote>\n";

	    $psgiresult .= "<debug>okay to send the delta.</debug>\n";
	    $psgiresult .= "<logpath>".$logpath."</logpath>\n";
	    $psgiresult .= "</debug>\n";
	}
	$startedat = time();

	$spell = "/usr/local/bin/sudo zfs send -vi ".$startsnapshot." ".$endsnapshot." 2>>".$logpath." | /usr/local/bin/pv -q -L 50M 2>>".$logpath." | ssh ".$remotedcip." sudo zfs receive -d ".$remotedataset." 2>>".$logpath." &";

	uwsgi::spool({spell => $spell});

	if ($debug > 0) {
	    $formattedspell = $spell;
	    $formattedspell =~ s/&/&amp;/g;
	    $psgiresult .= "<debug>replication spell: ".$formattedspell."</debug>\n";
	}
	if ($debug > 0) {
	    $psgiresult .= "<debug>zfs send invocation took ".(time() - $startedat)." seconds</debug>\n";
	}
	return 0;


	# if first snapshot doesn't exist on the remote - then bail out
	if ($firstsnapexists == 0) {
	    $errormessage = "start snapshot doesn't exist on the remote side.";
	return 1;
	}

	if ($secondsnapexists == 1) {
	    $errormessage = "end snapshot already exists on the remote side.";
	    return 1;
	}

	# now check if we're not sending it now
	if (getsendingstatus() > 0) {
	    $errormessage = "seems like we're already sending.";
	    return 1;
	}

	# now send it
	$startsnapshotescaped = $startsnapshot;
        $startsnapshotescaped =~ s/\//--/g;
        $endsnapshotescaped = $endsnapshot;
        $endsnapshotescaped =~ s/\//--/g;
        $logpath = $loglocation."/zfs-send-".$remotedcip."-".$startsnapshotescaped."-".$endsnapshotescaped.".log";
	if ($debug > 0) {
	    $psgiresult .= "<debug>\n";
	    $psgiresult .= "<firstsnapexistsonremote>".$firstsnapexists."</firstsnapexistsonremote>\n";
	    $psgiresult .= "<secondsnapexistsonremote>".$secondsnapexists."</secondsnapexistsonremote>\n";

	    $psgiresult .= "<debug>okay to send the delta.</debug>\n";
	    $psgiresult .= "<logpath>".$logpath."</logpath>\n";
	    $psgiresult .= "</debug>\n";
	}
	$startedat = time();

	$spell = "/usr/local/bin/sudo zfs send -vi ".$startsnapshot." ".$endsnapshot." 2>>".$logpath." | /usr/local/bin/pv -q -L 50M 2>>".$logpath." | ssh ".$remotedcip." sudo zfs receive -d ".$remotedataset." 2>>".$logpath." &";

	uwsgi::spool({spell => $spell});

	if ($debug > 0) {
	    $formattedspell = $spell;
	    $formattedspell =~ s/&/&amp;/g;
	    $psgiresult .= "<debug>replication spell: ".$formattedspell."</debug>\n";
	}
	if ($debug > 0) {
	    $psgiresult .= "<debug>zfs send invocation took ".(time() - $startedat)." seconds</debug>\n";
	}
	return 0;

    } else {
	if (!defined($remotedcip)) {
	    $errormessage = "remote dc ip not supplied.";
	} else {
	    if (!defined($remotedataset)) {
		$errormessage = "remote dataset not supplied.";
	    } else {
		if (!defined($startsnapshot)) {
        	    $errormessage = "start snapshot not supplied.";
		} else {
        	    $errormessage = "end snapshot not supplied.";
		}
	    }
	}
	return 1;
    }
}

sub targetcreate() {

    my $ug;
    my $uuid;
    my $ctladmlogpath;
    my $successflag = 0;
    my $messageerror;
    my $messageinfo;

    if (defined($targetname) && $targetname ne "null" &&
        defined($deviceid) && $deviceid ne "null" &&
        defined($scsiname) && $scsiname ne "null" &&
        defined($lunid) && $lunid ne "null" &&
        defined($vendor) && $vendor ne "null") {
        $ug = Data::UUID -> new;
        $uuid = $ug -> create_str();

        $ctladmlogpath = "/tmp/ctladm.log.".$uuid;
        $spell = $sudopath." /usr/sbin/ctladm create -b block -o file=".$targetname." -o vendor=".$vendor." -o scsiname=".$scsiname." -o ctld_name=".$scsiname." -d ".$deviceid." -l ".$lunid." > ".$ctladmlogpath." 2>&1";

        # locking the LUN
        # global locking
        lockCtlOp();

        system($spell);

        # unlocking the LUN
        unlockCtlOp();

        open(CTLADMLOG, "<", $ctladmlogpath) or return 1;
        while (!eof(CTLADMLOG)) {
            $line = readline(*CTLADMLOG);
            if(index($line, "LUN created successfully") != -1) {
                $successflag = 1;
            } else {
                if($successflag == 0) {
                    $messageerror = $messageerror.$line;
                } else {
                    $messageinfo = $messageinfo.$line;
                }
            }
        }
        close(CTLADMLOG);
        if ($debug == 0) {
            unlink($ctladmlogpath);
        }
        if($successflag == 0) {
            $errormessage = $messageerror;
            return 1;
        } else {
            $warningmessage = $messageerror;
            $infomessage = $messageinfo;
            return 0;
        }
    } else {
        $errormessage = "missing parameters to do create command.";
        return 1;
    }
}

sub diffcreate() {

    my $logpath;
    my $endsnapshotescaped;
    my $formattedspell;
    my $exit_code;

    if (defined($endsnapshot)) {

        # make sure local snapshots exists
        $spell = "zfs list -H -t snapshot -o name ".$endsnapshot;
        $exit_code = system($spell);
        if ($exit_code != 0) {
            $errormessage = "end snapshot doesn't exist.";
            return 1;
        }
        if (defined($startsnapshot)) {
            $spell = "zfs list -H -t snapshot -o name ".$startsnapshot;
            $exit_code = system($spell);
            if ($exit_code != 0) {
                $errormessage = "start snapshot doesn't exist.";
                return 1;
            }
            if ((split '@', $startsnapshot)[0] ne (split '@', $endsnapshot)[0]) {
                $errormessage = "start and end snapshots from different datasets.";
                return 1;
            }
        }

        # now create diff
        $endsnapshotescaped = $endsnapshot;
        $endsnapshotescaped =~ s/\//--/g;
        $logpath = $loglocation."/zfs-diffcreate-".$endsnapshotescaped.".log";
        if ($debug > 0) {
            $psgiresult .= "<debug>\n";
            $psgiresult .= "<debug>okay to create the diff.</debug>\n";
            $psgiresult .= "<logpath>".$logpath."</logpath>\n";
            $psgiresult .= "</debug>\n";
        }

        if (defined($startsnapshot)) {
            $spell = "/usr/local/bin/sudo zfs send -vi ".$startsnapshot." ".$endsnapshot." > ".$diffpath.+(split '@', $endsnapshotescaped)[-1].".diff 2>>".$logpath;

            my ($drivenumber, $startversion) = $startsnapshot =~ /drive_(\d+)_version_(\d+)/;
            my $firstdiff = (get_sorted_diffs($diffpath, $drivenumber))[0];
            my ($firstversion) = $firstdiff =~ /version_(\d+)/;

            if ($firstversion eq "" or $startversion eq "" or $drivenumber eq "") {
                makeerror("Failed to get drive or version: firstversion: ".$firstversion." startversion: ".$startversion." drivenumber: ".$drivenumber);
                return 1;
            }

            if ($firstversion ne $startversion) {
                $spell .= " && /usr/local/bin/sudo zfs send -v ".$startsnapshot." > ".$diffpath.$firstdiff."_".$startversion." 2>>".$logpath." && mv ".$diffpath.$firstdiff."_".$startversion." ".$diffpath.$firstdiff;
            }
            $spell .= " &";
        } else {
            $spell = "/usr/local/bin/sudo zfs send -v ".$endsnapshot." > ".$diffpath.+(split '@', $endsnapshotescaped)[-1].".diff 2>>".$logpath." &";
        }

        uwsgi::spool({spell => $spell});

        if ($debug > 0) {
            $psgiresult .= "<debug>replication spell: ".formatspell($spell)."</debug>\n";
        }
        return 0;
	
    } else {
        if (!defined($startsnapshot)) {
        	    $errormessage = "start snapshot not supplied.";
        } else {
        	    $errormessage = "end snapshot not supplied.";
        }
        return 1;
    }
}


sub makeerror {
    ($errormessage) = @_[0];
    return 0;
}

sub implsystem {
    chomp($_[0] = `$_[1]`);
    my $result = $?;

    if ($debug > 0)
    {
        $psgiresult .= "<debug><comand>".formatspell($_[1])."</comand>\n";
        $psgiresult .= "<result>".$result."</result>\n";
        $psgiresult .= "<output>".formatspell($_[0])."</output></debug>\n";
    }
    return ($result == 0 or makeerror(formatspell($_[0])));
}

sub mysystem {
    return implsystem($_[0], $_[1]." 2>&1");
}

sub mypopen {
    implsystem(my $out, $_[0]);
    return $out;
}

sub getsmartclone() {

    !defined($clonesource) and return makeerror("clonesource not supplied.");
    !defined($clonename) and return makeerror("clonename not supplied.");
    !defined($deviceid) and return makeerror("deviceid not supplied.");

    my $startedat = time();

    mysystem(my $lastsnapshot, "zfs list -Ho name -t snapshot -r ".$clonesource) or return 0;
    ($lastsnapshot eq "") and return makeerror("there is no any snapshot in ".$clonesource);

    $lastsnapshot = (split /\n/, $lastsnapshot)[-1];
    $psgiresult .= "<lastsnapshot>".$lastsnapshot."</lastsnapshot>\n";
    
    lockCtlOp();
    my $port = mypopen($sudopath." ctladm portlist -q | awk '\$NF ~ /:".$deviceid.",/ {print \$1}'");
    ($port eq "") and return makeerror("there is no port like that: ".$deviceid);
    unlockCtlOp();

    lockCtlOp();
    my $info = mypopen($sudopath." ctladm portlist -qvp ".$port);
    unlockCtlOp();
    ($info eq "") and return makeerror("failed to get port information: ".$deviceid);

    my ($target) = $info =~ /Target: (\S+)/;
    my ($lun)    = $info =~ /LUN 0: (\d+)/;
    ($target eq "" or $lun eq "") and return makeerror("failed to parse port information: ".$info);

    $psgiresult .= "<target>".$target."</target>\n";
    $psgiresult .= "<lun>".$lun."</lun>\n";

    my $origin = "";
    my $written = 0;
    if (mysystem(my $res, "zfs get -Hpo value origin,written ".$clonename)) {
        ($origin, $written) = split(/\n/, $res);
        ($origin eq "-") and return makeerror($clonename." is not clone.");

        $psgiresult .= "<origin>".$origin."</origin>\n";
        $psgiresult .= "<written>".$written."</written>\n";
    }

    if ($written != 0 or $origin ne $lastsnapshot) {
        lockCtlOp();
        my $lun2 = mypopen($sudopath." ctladm devlist | awk '\$NF == \"".$deviceid."\" {print \$1}'");
        unlockCtlOp();
        if ($lun2 ne "") {
            if ($lun2 ne $lun) {
                $psgiresult .= "<warning>lun (".$lun.") ne lun2 (".$lun2.")</warning>\n";
            }
            lockCtlOp();
            my $connection = mypopen($sudopath." ctladm islist | awk '\$NF == \"".$target."\"'");
            unlockCtlOp();
            ($connection ne "") and return makeerror("there is an active iscsi session: ".$connection);

            lockCtlOp();
            mysystem(my $res, $sudopath." ctladm remove -b block -l ".$lun) or return 0;
            unlockCtlOp();
        }

        if ($origin ne "") {
            mysystem(my $res, $sudopath." zfs destroy -r ".$clonename) or return 0;
        }
        mysystem(my $res, $sudopath." zfs clone ".$lastsnapshot." ".$clonename) or return 0;
        mysystem(my $res, $sudopath." zfs snapshot ".$clonename."\@0") or return 0;

        lockCtlOp();
        mysystem(my $res, $sudopath." ctladm create -b block -o file=".$zvol.$clonename." -o vendor=FREE_TT -o ctld_name=".$target.",lun,0 -d ".$deviceid." -l ".$lun) or return 0;
        unlockCtlOp();
    } else {
        $psgiresult .= "<actualclone>nothing to do</actualclone>\n";
    }
    if ($debug > 0) {
        $psgiresult .= "<debug>getsmartclone tooks ".(time() - $startedat)." seconds</debug>\n";
    }
    return 1;
}

uwsgi::spooler(
    sub {
        my ($env) = @_;
        system($env->{'spell'});
        return uwsgi::SPOOL_OK;
    }
);

$app = sub {
    # zeroing everything
    $psgiresult = "";
    $errormessage = "";
    $action = "null";
    $snapsource = "null";
    $snapsourcefmt;
    $snapname = "null";
    $bookmarkname = "null";
    $victim = "null";
    $clonesource = undef;
    $clonesourcefmt = undef;
    $clonename = undef;
    $clonenamefmt = undef;
    $victimfmt = "null";
    $snapshot = "null";
    $snapshotfmt = "null";
    $targetname = "null";
    $device = "null";
    $lun = "null";
    $deviceid = "null";
    $result = -1;
    $scsiname = "null";
    $lunid = "null";
    $lunidinfo = "null";
    $deviceidinfo = "null";
    $vendorinfo = "null";
    $vendor = "null";
    $parselogresult = "null";
    $startsnapshot = undef;
    $endsnapshot = undef;
    $remotedcip = undef;
    $remotedataset = undef;
    $debug = undef;
    undef(@logcontents);

    # creating or obtaining a semaphore for CTL locking
    # first trying to create new
    unless (defined($sem)) {
	$sem = IPC::Semaphore->new(49152, 1, 0722 | IPC_CREAT | IPC_EXCL);
    }
    unless ($sem) {
	# seems like it exists already
        $sem = IPC::Semaphore->new(49152, 1, 1) or die "could not obtain semaphore.";
    }
    # so we created or obtained a new one, let's reset it now if we've been just started
    if ($juststarted == 1) {
	$sem->setval(0, 0);
    }

    # creating or obtaining a semaphore for ctl.conf locking
    # first trying to create new
    unless (defined($confsem)) {
	$confsem = IPC::Semaphore->new(49153, 1, 0722 | IPC_CREAT | IPC_EXCL);
    }
    unless ($confsem) {
	# seems like it exists already
        $confsem = IPC::Semaphore->new(49153, 1, 1) or die "could not obtain semaphore.";
    }
    # so we created or obtained a new one, let's reset it now if we've been just started
    if ($juststarted == 1) {
	# finishing the startup sequence
	$juststarted = 0;
	$confsem->setval(0, 0);

	# a timeout to disallow neighbor workers setting up the semaphore again
	sleep 5;
    }

    # parsing REQUEST_URI
    $env = shift;
    @request = split(/[\?\&]/, $env -> {'REQUEST_URI'});
    $i = 0;
    while ($i < @request) {
        chomp($request[$i]);
        if ($request[$i] =~ "^action") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                 $action = $tmp[1];
            } else {
                 $action = "null";
            }
        }
        if ($request[$i] =~ "^snapsource") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $snapsource = $tmp[1];
            } else {
                $snapsource = "null";
            }
        }
        if ($request[$i] =~ "^snapname") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $snapname = $tmp[1];
            } else {
                $snapname = "null";
            }
        }
        if ($request[$i] =~ "^bookmarkname") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $bookmarkname = $tmp[1];
            } else {
                $bookmarkname = "null";
            }
        }
        if ($request[$i] =~ "^victim") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $victim = $tmp[1];
            } else {
                $victim = "null";
            }
        }
        if ($request[$i] =~ "^clonesource") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $clonesource = $tmp[1];
            } else {
                $clonesource = "null";
            }
        }
        if ($request[$i] =~ "^clonename") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $clonename = $tmp[1];
            } else {
                $clonename = "null";
            }
        }
        if ($request[$i] =~ "targetname") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $targetname = $tmp[1];
            } else {
                $targetname = "null";
            }
        }
        if ($request[$i] =~ "device") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $device = $tmp[1];
            } else {
                $device = "null";
            }
        }
        if ($request[$i] =~ "lun") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $lun = $tmp[1];
            }  else {
                $lun = "null";
            }
        }
        if ($request[$i] =~ "remotedcip") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $remotedcip = $tmp[1];
            } else {
                $remotedcip = "null";
            }
        }
        if ($request[$i] =~ "remotedataset") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $remotedataset = $tmp[1];
            } else {
                $remotedataset = "null";
            }
        }
        if ($request[$i] =~ "startsnapshot") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $startsnapshot = $tmp[1];
            } else {
                $startsnapshot = "null";
            }
        }
        if ($request[$i] =~ "endsnapshot") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $endsnapshot = $tmp[1];
            } else {
                $endsnapshot = "null";
            }
        }
        if ($request[$i] =~ "snapshot") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $snapshot = $tmp[1];
            } else {
                $snapshot = "null";
            }
        }
        if ($request[$i] =~ "deviceid") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $deviceid = $tmp[1];
            } else {
                $deviceid = "null";
            }
        }
        if ($request[$i] =~ "scsiname") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $scsiname = $tmp[1];
            } else {
                $scsiname = "null";
            }
        }
        if ($request[$i] =~ "lunid") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $lunid = $tmp[1];
            } else {
                $lunid = "null";
            }
        }
        if ($request[$i] =~ "vendor") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $vendor = $tmp[1];
            } else {
                $vendor = "null";
            }
        }
        if ($request[$i] =~ "debug") {
            @tmp = split(/=/, $request[$i]);
            if (defined($tmp[1])) {
                $debug = $tmp[1];
            } else {
                $debug = "null";
            }
        }
        $i++;
    }

    getxmlhead();
    $psgiresult .= "<action>".$action."</action>\n";
    ACTION:
    for ($action) {
        if (/^snapshot/) {
            $psgiresult .= "<snapsource>".$snapsource."</snapsource>\n";
            $psgiresult .= "<snapname>".$snapname."</snapname>\n";
            $result = getsnapshot();
            handleresult();
            last ACTION;
        }
        if (/^bookmark/) {
            $psgiresult .= "<snapsource>".$snapsource."</snapsource>\n";
            $psgiresult .= "<bookmarkname>".$snapname."</bookmarkname>\n";
            $result = getbookmark();
            handleresult();
            last ACTION;
        }
        if (/^clone/) {
            $psgiresult .= "<clonesource>".$clonesource."</clonesource>\n";
            $psgiresult .= "<clonename>".$clonename."</clonename>\n";
            $result = getclone();
            handleresult();
            last ACTION;
        }
        if (/^destroy/) {
            $psgiresult .= "<victim>".$victim."</victim>\n";
            $result = destroyentity();
            handleresult();
            last ACTION;
        }
        if (/^status/) {
            $result = getstatus();
            handlestatus();
            last ACTION;
        }
        if (/^ipcstats/) {
            $result = getipcstats();
            last ACTION;
        }
        if (/^targetmount/) {
            $psgiresult .= "<targetname>".$targetname."</targetname>\n";
            $psgiresult .= "<device>".$device."</device>\n";
            $psgiresult .= "<lun>".$lun."</lun>\n";
            $result = mounttarget();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
            }
            last ACTION;
        }
        if (/^targetenable/) {
            $psgiresult .= "<targetname>".$targetname."</targetname>\n";
            $result = enabletarget();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^targetdisable/) {
            $psgiresult .= "<targetname>".$targetname."</targetname>\n";
            $result = disabletarget();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<debug>result:".$result."</debug>\n";
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^release/) {
            $psgiresult .= "<victim>".$victim."</victim>\n";
            $result = getrelease();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
                if (@logcontents > 0) {
                    $psgiresult .= "<log>\n";
                    $i = 0;
                    while ($i < @logcontents) {
                        $psgiresult .= "<entry>".$logcontents[$i]."</entry>\n";
                        $i++
                    }
                    $psgiresult .= "</log>\n";
                }
            }
            last ACTION;
        }
        if (/^reload/) {
            $result = getreload();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^send$/) {
            $psgiresult .= "<startsnapshot>".$startsnapshot."</startsnapshot>\n";
            $psgiresult .= "<endsnapshot>".$endsnapshot."</endsnapshot>\n";
            $psgiresult .= "<remotedcip>".$remotedcip."</remotedcip>\n";
            $psgiresult .= "<remotedataset>".$remotedataset."</remotedataset>\n";
            $result = senddelta();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^sendlist/) {
            $result = getsendingstatus();
            if ($result != -1) {
                $psgiresult .= "<status>success</status>\n";
                $psgiresult .= "<sendingprocesses>".$result."</sendingprocesses>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^senddetails/) {
            $psgiresult .= "<startsnapshot>".$startsnapshot."</startsnapshot>\n";
            $psgiresult .= "<endsnapshot>".$endsnapshot."</endsnapshot>\n";
            $psgiresult .= "<remotedcip>".$remotedcip."</remotedcip>\n";
            $result = getsendingdetails();
            if ($result != -1) {
                $psgiresult .= "<status>success</status>\n";
                $psgiresult .= "<sendingprocesses>".$result."</sendingprocesses>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^receivelist/) {
            $result = getreceivingstatus();
            if ($result != -1) {
                $psgiresult .= "<status>success</status>\n";
                $psgiresult .= "<active>".$result."</active>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^targetconfig/) {
            my %result = gettargetconfig();
            if(%result)
            {
                $psgiresult .= "<status>success</status>\n";
                while (my ($key, $val) = each %result)
                {
                    $psgiresult .= "<$key>$val</$key>\n";            
                }
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^targetinfo/) {
            $result = gettargetinfo();
            if ($result != -1) {
                $psgiresult .= "<status>success</status>\n";
                $psgiresult .= "<targetname>".$targetname."</targetname>\n";
                $psgiresult .= "<targetinfo>".$result."</targetinfo>\n";
                $psgiresult .= "<lunidinfo>".$lunidinfo."</lunidinfo>\n";
                $psgiresult .= "<deviceidinfo>".$deviceidinfo."</deviceidinfo>\n";
                $psgiresult .= "<vendorinfo>".$vendorinfo."</vendorinfo>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^rollback/) {
            $psgiresult .= "<snapshot>".$snapshot."</snapshot>\n";
            $result = getrollback();
            if ($result != -1) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^version/) {
            $psgiresult .= "<status>success</status>\n";
            $psgiresult .= "<version>".$version."</version>\n";
            last ACTION;
        }
        if (/^targetcreate/) {
            $psgiresult .= "<targetname>".$targetname."</targetname>\n";
            $psgiresult .= "<deviceid>".$deviceid."</deviceid>\n";
            $psgiresult .= "<scsiname>".$scsiname."</scsiname>\n";
            $psgiresult .= "<lunid>".$lunid."</lunid>\n";
            $psgiresult .= "<vendor>".$vendor."</vendor>\n";
            $result = targetcreate();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
                if($warningmessage ne "") {
                    $psgiresult .= "<warning>".$warningmessage."</warning>\n";
                }
                if($infomessage ne "") {
                    $psgiresult .= "<info>".$infomessage."</info>\n";
                }
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^diffcreate$/) {
            $psgiresult .= "<startsnapshot>".$startsnapshot."</startsnapshot>\n";
            $psgiresult .= "<endsnapshot>".$endsnapshot."</endsnapshot>\n";
            $result = diffcreate();
            if ($result == 0) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        if (/^smartclone$/) {
            $psgiresult .= "<clonesource>".$clonesource."</clonesource>\n";
            $psgiresult .= "<clonename>".$clonename."</clonename>\n";
            $psgiresult .= "<deviceid>".$deviceid."</deviceid>\n";
            if (getsmartclone()) {
                $psgiresult .= "<status>success</status>\n";
            } else {
                $psgiresult .= "<status>error</status>\n";
                $psgiresult .= "<errormessage>".$errormessage."</errormessage>\n";
            }
            last ACTION;
        }
        $psgiresult .= "<status>error</status>\n";
        $psgiresult .= "<status>You have requested something that I don't understand.</status>\n";
    }
    getxmlfoot();
    $requests++;

    return [
    '200',
    [ 'Content-Type' => 'text/xml'],
    [ $psgiresult ]
    ];
}
