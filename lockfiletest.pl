#!/usr/bin/perl -w

require 5.004;
use strict;
use DirHandle;			# DirHandle()
use Cwd;				# cwd()
use Getopt::Std;		# getopts()
use File::Path;			# mkpath(), rmtree()
use File::stat;			# stat(), lstat()
use POSIX qw(locale_h);	# setlocale()
use Fcntl;				# sysopen()
use IO::File;			# recursive open in parse_config_file


sub print_err {
	my $str		= shift(@_);
        print $str, "\n",
}

*print_cmd = *print_msg = *print_warn = *syslog_warn = *syslog_err = *print_err;


my $test			= 0; # turn verbose on, but don't execute
                                     # any filesystem commands
my %config_vars = ( lockfile => '/tmp/lockfiletest', wait_for_lock => 1 );

my $stop_on_stale_lockfile = 0;

print "$$: start\n";

add_lockfile();

print "$$: enter\n";
sleep 3;
print "$$: leave\n";

remove_lockfile();

print "$$: done\n";

# accepts no arguments
# returns undef if lockfile isn't defined in the config file, and 1 upon success
# also, it can make the program exit with 1 as the return value if it can't create the lockfile
#
# we don't use bail() to exit on error, because that would remove the
# lockfile that may exist from another invocation
#
# if a lockfile exists, we try to read it (and stop if we can't) to get a PID,
# then see if that PID exists.  If it does, we stop, otherwise we assume it's
# a stale lock and remove it first.
sub add_lockfile {
	my $wait_for_lock = $config_vars{'wait_for_lock'};

	while (1) {
		my $ret = try_add_lockfile();
		return $ret unless ($ret == 2 || $ret == 3);
		if ($wait_for_lock) {
			#sleep 0.1;
		} else {
			if (2 == $ret) {
				print_err ("Lockfile $config_vars{'lockfile'} exists and so does its process, can not continue");
				syslog_err("Lockfile $config_vars{'lockfile'} exists and so does its process, can not continue");
			} else {
				print_err ("Could not write lockfile $config_vars{'lockfile'}: $!", 1);
				syslog_err("Could not write lockfile $config_vars{'lockfile'}");
			}
			exit(1);
		}
	}
}


# implements all of add_lockfile() except for the wait_for_lock flag. If the lockfile
# is blocked, return 2 or 3 (depending on the specific condition) so the caller (add_lockfile())
# can react according to the wait_for_lock setting.
sub try_add_lockfile {
	# if we don't have a lockfile defined, just return undef
	if (!defined($config_vars{'lockfile'})) {
		return (undef);
	}
	
	my $lockfile = $config_vars{'lockfile'};
	
	# valid?
	if (0 == is_valid_local_abs_path($lockfile)) {
		print_err ("Lockfile $lockfile is not a valid file name", 1);
		syslog_err("Lockfile $lockfile is not a valid file name");
		exit(1);
	}
	
	# does a lockfile already exist?
        if (1 == is_real_local_abs_path($lockfile)) {
            if(!open(LOCKFILE, $lockfile)) {
                print_err ("Lockfile $lockfile exists and can't be read, can not continue!", 1);
                syslog_err("Lockfile $lockfile exists and can't be read, can not continue");
                exit(1);
            }
            my $pid = <LOCKFILE>;
            chomp($pid);
            close(LOCKFILE);
            if(kill(0, $pid)) {
                return 2;
            } else {
		if(1 == $stop_on_stale_lockfile) {
		    print_err ("Stale lockfile $lockfile detected. You need to remove it manually to continue", 1);
		    syslog_err("Stale lockfile $lockfile detected. Exiting.");
		    exit(1);
	        } else {
	            print_warn("Removing stale lockfile $lockfile", 1);
		    syslog_warn("Removing stale lockfile $lockfile");
		    remove_lockfile();
	        }
            }
        }

	
	# create the lockfile
	print_cmd("echo $$ > $lockfile");
	
	if (0 == $test) {
		# sysopen() can do exclusive opens, whereas perl open() can not
		my $result = sysopen(LOCKFILE, $lockfile, O_WRONLY | O_EXCL | O_CREAT, 0644);
		if (!defined($result) || 0 == $result) {
			return 2;
		}
		
		# print PID to lockfile
		print LOCKFILE $$;
		
		$result = close(LOCKFILE);
		if (!defined($result) || 0 == $result) {
			print_warn("Could not close lockfile $lockfile: $!", 2);
		}
	}
	
	return (1);
}





# accepts no arguments
#
# returns undef if lockfile isn't defined in the config file
# return 1 upon success or if there's no lockfile to remove
# warn if the PID in the lockfile is not the same as the PID of this process
# exit with a value of 1 if it can't read the lockfile
# exit with a value of 1 if it can't remove the lockfile
#
# we don't use bail() to exit on error, because that would call
# this subroutine twice in the event of a failure
sub remove_lockfile {
	# if we don't have a lockfile defined, return undef
	if (!defined($config_vars{'lockfile'})) {
		return (undef);
	}
	
	my $lockfile = $config_vars{'lockfile'};
	my $result = undef;
	
	if ( -e "$lockfile" ) {
	        if(open(LOCKFILE, $lockfile)) {
		  chomp(my $locked_pid = <LOCKFILE>);
		  close(LOCKFILE);
		  if($locked_pid != $$) {
		    print_warn("About to remove lockfile $lockfile which belongs to a different process (this is OK if it's a stale lock)");
		  }
		} else {
		  print_err ("Could not read lockfile $lockfile: $!", 0);
		  syslog_err("Error! Could not read lockfile $lockfile: $!");
		  exit(1);
		}
		print_cmd("rm -f $lockfile");
		if (0 == $test) {
			$result = unlink($lockfile);
			if (0 == $result) {
				print_err ("Could not remove lockfile $lockfile", 1);
				syslog_err("Error! Could not remove lockfile $lockfile");
				exit(1);
			}
		}
	} else {
		print_msg("No need to remove non-existent lock $lockfile", 5);
	}
	
	return (1);
}






# accepts path
# returns 1 if it's a real absolute path that currently exists
# returns 0 otherwise
sub is_real_local_abs_path {
	my $path	= shift(@_);
	
	if (!defined($path)) { return (undef); }
	if (1 == is_valid_local_abs_path($path)) {
		# check for symlinks first, since they might not link to a real file
		if ((-l "$path") or (-e "$path")) {
			return (1);
		}
	}
	
	return (0);
}

# accepts path
# returns 1 if it's a syntactically valid absolute path
# returns 0 otherwise
sub is_valid_local_abs_path {
	my $path	= shift(@_);
	
	if (!defined($path)) { return (undef); }
	if ($path =~ m/^\//) {
		if (0 == is_directory_traversal($path)) {
			 return (1);
		}
	}
	
	return (0);
}

# accepts path
# returns 1 if it's a syntactically valid non-absolute (relative) path
# returns 0 otherwise
# does not check for directory traversal, since we want to use 
# a different error message if there is ".." in the path
sub is_valid_local_non_abs_path {
	my $path	= shift(@_);
	
	if (!defined($path)) { return (0); }
	if ($path =~ m/^\//) {
		return (0);		# Absolute path => bad
	}
	
	if ($path =~ m/^\S/) {
		 return (1);		# Starts with a non-whitespace => good
	} else {
		 return (0);		# Empty or starts with whitespace => bad
	}
}

# accepts path
# returns 1 if it's a directory traversal attempt
# returns 0 if it's safe
sub is_directory_traversal {
	my $path = shift(@_);
	
	if (!defined($path)) { return (undef); }
	
	# /..
	if ($path =~ m/\/\.\./) { return (1); }
	
	# ../
	if ($path =~ m/\.\.\//) { return (1); }
	return (0);
}
