#!/usr/bin/perl

# Copyright (c) 2010 Nicolas P. M. Legrand <nlegrand@ethelred.fr>
# Copyright (c) 2016 Giovanni Bechis <giovanni@paclan.it>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# autoflush buffer
$| = 1;

use strict;
use warnings;
use Archive::Tar;
use Data::Dumper;
use Digest::SHA;
use Fcntl qw(O_WRONLY O_EXCL);
use File::Path qw(make_path);
use File::Basename;
use LWP::UserAgent;
use LWP::Simple;
use Time::HiRes qw(gettimeofday tv_interval);
# use OpenBSD::Pledge;

my $VERSION = "1.2.3";
my %opts = ();
my $checkpkg = 0;
my $base_set;
my $xbase_set;
my $pkgtocheck = 'mplayer';
my $server;
my $openbsd_ver;
my $hw;
my $sets_dir; #path where to download sets
my $ua;	# UserAgent
my $request;
my $resp;

my $progname = $0;
$progname =~ s,.*/,,;    # only basename left in progname
$progname =~ s,.*\\,, if $^O eq "MSWin32";
$progname =~ s/\.\w*$//; # strip extension if any

# pledge(qw( stdio rpath cpath wpath inet )) || die "Unable to pledge: $!";

sub wantlib_check {
	# Set PKG_DBDIR do /var/empty to force download of new package
	my $wantlib = `env PKG_DBDIR=/var/empty PKG_PATH=$server/$openbsd_ver/packages/$hw/ pkg_info -f $pkgtocheck | grep wantlib`;
	my $tar = Archive::Tar->new;
	$tar->read($sets_dir . "/" . $base_set);
	my $xtar = Archive::Tar->new;
	$xtar->read($sets_dir . "/" . $xbase_set);

	my @a_wantlib = split(" ", $wantlib);
	my @p_wantlib;
	my $lib;
	my $xlib;
	my @matchfile;
	my @xmatchfile;
	for (my $i = 1; $i <= @a_wantlib; $i+=2) {
		@p_wantlib = split(/\./, $a_wantlib[$i]);
		$lib = "./usr/lib/lib" . $p_wantlib[0] . ".so.$p_wantlib[1].$p_wantlib[2]";
		$xlib = "./usr/X11R6/lib/lib" . $p_wantlib[0] . ".so.$p_wantlib[1].$p_wantlib[2]";
		if(( not $tar->contains_file($lib)) && (not $xtar->contains_file($xlib))) {
			# check if a similar library exists to skip wantlib 
			# installed by packages
			@matchfile = glob("/usr/lib/lib" . $p_wantlib[0] . ".so.*");
			@xmatchfile = glob("/usr/X11R6/lib/lib" . $p_wantlib[0] . ".so.*");
			if( (@matchfile ne 0) or (@xmatchfile ne 0)) {
				print "Warning: $lib not in sync with base\n";
			}
		}
	}
}

sub format_check { # format_check(\@list)

	my $list_ref = shift @_;
	my $col_size = int($#{$list_ref} / 4);
	for (my $i = 0; $i <= $col_size; $i++) {
		printf "%-20s",$list_ref->[$i];
		for (my $j = 1; $j <= 3; $j++) {
		    printf "%-20s",$list_ref->[$i + ($col_size + 1) * $j]
			if (defined($list_ref->[$i + ($col_size + 1) * $j]));
		}
	        print "\n";
	}
}

sub download {
	my $uri = shift;
	my $file = shift;

	my $content = get("$uri/$file");

	return $content;
}

sub download_and_save {
	my $uri = shift;
	my $file = shift;

	print "Saving to '$file'...";
	if(getstore("$uri/$file", $file)) {
		print " done\n";
	} else {
		print " error\n";
	}
}

sub cksum256 {
	my $ifile = shift;

	my $alg = "SHA256";
        my $sha = Digest::SHA->new($alg);
	my $digest;
	my $line;

	$sha->addfile($ifile);

	$digest = $sha->hexdigest();
	$line = $alg . " (" . basename($ifile) . ") = " . $digest;
	return $line;
}

if ($#ARGV > -1) {
        print "usage: snapdl\n";
	exit 1;
}

my $snapdl_dir = "$ENV{'HOME'}/.snapdl";
if (! -d $snapdl_dir) {
	printf "Creating $ENV{'HOME'}/.snapdl\n";
	mkdir "$ENV{'HOME'}/.snapdl" or die "can't mkdir $ENV{'HOME'}/.snapdl";
}

print "Which version do you want do download? [snapshots] ";
chomp($openbsd_ver = <STDIN>);
if ($openbsd_ver !~ /[0-9]\.[0-9]/) {
	$openbsd_ver = "snapshots";
}

$ua = LWP::UserAgent->new;
$ua->agent("$progname/$VERSION ");

my $i_want_a_new_mirrors_dat;
if (-e "$snapdl_dir/mirrors.dat") {
	my $mtime = (stat("$snapdl_dir/mirrors.dat"))[9];
	my $mod_date = localtime $mtime;
	print "You got your mirror list since $mod_date\n";
	print "Do you want a new one? [no] ";
	chomp($i_want_a_new_mirrors_dat = <STDIN>);
} 
if (! -e "$snapdl_dir/mirrors.dat" || $i_want_a_new_mirrors_dat =~ /y|yes/i) {
	chdir($snapdl_dir);
	download_and_save("http://www.OpenBSD.org/build", "mirrors.dat");
}

open my $mirrors_dat, '<', "$ENV{'HOME'}/.snapdl/mirrors.dat" or die "can't open $ENV{'HOME'}/.snapdl/mirrors.dat";

my %mirrors;
my $current_country;
# autovivify %mirrors :
# $mirrors{'Country'} = ["not checked", [qw(ftp://blala.com http://blili.org)]]
while (<$mirrors_dat>) {
	chomp;
	if (/^GC\s+([a-zA-Z ]+)/) {
		$current_country = $1;
		if (! defined($mirrors{$current_country}->[0])) {
			$mirrors{$current_country}->[0] = "not checked";
		}
		
	} elsif (/(?:^UF|^UH)\s+([a-zA-Z0-9\.:\/-]+)/
	    && ! ($1 =~ m!ftp.OpenBSD.org/pub/OpenBSD/!)) {
		push @{ $mirrors{$current_country}->[1] }, $1;
	}
}

close $mirrors_dat;

my $fh_countries;
if (-e "$snapdl_dir/countries") {
	open $fh_countries, '<', "$ENV{'HOME'}/.snapdl/countries" or die "can't open $ENV{'HOME'}/.snapdl/countries";
	while (my $country = <$fh_countries>) {
		chomp($country);
		if (defined($mirrors{$country})) {
			$mirrors{$country}->[0] = "checked";
		}
	}
	close $fh_countries;
}

COUNTRY: {
        print "Which countries you want to download from?:\n";
	my @countries;
        for (sort keys %mirrors) {
		my $box = ($mirrors{$_}->[0] eq "checked") ? "[x]" : "[ ]";
		push @countries, "$box $_";
        }
	format_check(\@countries);
        printf "Countries names? (or 'done') [done] ";
        chomp(my $line = <STDIN>);
        my $operation;
        my $pattern;
        if ($line eq "done" || $line eq "") {
                print "Write the chosen countries in ~/.snapdl/countries to check them by default? [no] ";
	        chomp($line = <STDIN>);
	        if ($line =~ /y|yes/i) {
		        open $fh_countries, '>', "$ENV{'HOME'}/.snapdl/countries"
                            or die "can't open $ENV{'HOME'}/.snapdl/countries";
		        for (keys %mirrors) {
			        if ($mirrors{$_}->[0] eq "checked") {
                                        printf $fh_countries "$_\n";
                                }
		        }
                close $fh_countries;
	        }
                last COUNTRY;
        } else {
                if ($line =~ /(\+|-)(.+)/) {
                        $operation = $1;
                        $pattern = $2;
                } else {
                        print "+re add countries with pattern re\n-re remove countries with pattern re\n";
                        redo COUNTRY;
                        
                }
                for my $country (sort keys %mirrors) {
                        if ($country =~ /$pattern/
                            && $operation eq '-') {
                                $mirrors{$country}->[0] = "not checked";
                        } elsif ($country =~ /$pattern/
                            && $operation eq '+') {
                                $mirrors{$country}->[0] = "checked";
                        }
                }
                redo COUNTRY;
        }
}

my @mirrors;
PROTOCOL: {
        printf "Protocols? ('ftp', 'http' or 'both') [http] ";
        chomp(my $line = <STDIN>);
        my $proto_pattern;
        if ($line =~ /^$|http/) {
                $proto_pattern = "^http";
        } elsif ($line =~ /ftp/) {
                $proto_pattern = "^ftp";
        } else {
                $proto_pattern = "^ftp|^http";
        }
        for (keys %mirrors) {
                if ($mirrors{$_}->[0] eq "checked") {
                        for (@{ $mirrors{$_}->[1] }) {
                                if (/$proto_pattern/) {
                                        push @mirrors, $_;
                                } 
                        }
                }   
        }
}

my $pretend = "no";
SETS: {
        $sets_dir = "$ENV{'HOME'}/OpenBSD";
        printf "Path to download sets? (or 'pretend' ) [$sets_dir] ";
        chomp(my $line = <STDIN>);
        if ($line eq "pretend") {
                $pretend = "yes";
                last SETS;
        } elsif ($line) {
                $sets_dir = $line;
        } 
        if (! -d $sets_dir) {
                make_path($sets_dir);
                die "Can't mkdir $sets_dir" if ($? != 0);
        }
        (! -d $sets_dir ) ? redo SETS : chdir($sets_dir);
}

my @platforms = ( "alpha",
                  "amd64",
                  "armish",
		  "armv7",
                  "hppa",
                  "i386",
                  "landisk",
                  "loongson",
		  "luna88k",
                  "macppc",
		  "octeon",
                  "sgi",
                  "sparc",
                  "sparc64",
                  "zaurus" );
HW: {
        chomp($hw = `uname -m`);
        printf "Platform? (or 'list') [$hw] ";
        chomp(my $line = <STDIN>);
        if ($line eq 'list') {
                print "Available platforms:\n";
                for (@platforms) {
                        print "    $_\n";
                }
                redo HW;
        } elsif ($line) {
                if ((grep {/$line/} @platforms) == 1) {
                        $hw = $line;
                        last HW;
                } else {
                        printf "Bad hardware platform name\n";
                        redo HW;
                }
        }
}

print "Getting SHA256 from main mirror\n";
my $SHA256 = download("http://ftp.OpenBSD.org/pub/OpenBSD/$openbsd_ver/$hw", "SHA256");
my $SHA256sig = download("http://ftp.OpenBSD.org/pub/OpenBSD/$openbsd_ver/$hw", "SHA256.sig");

if ( $SHA256 =~ /base([0-9]{2,2}).tgz/ ) {
        my $r = $1;
} else {
        die "No good SHA256 from http://ftp.OpenBSD.org/. Aborting.\n";
}



my %synced_mirror; # { 'http://mirror.com' => $time }
print "Let's locate mirrors synchronised with ftp.OpenBSD.org... ";
my $mirrored_SHA256 = "";
for my $candidat_server (@mirrors) {
        my $url = "${candidat_server}$openbsd_ver/$hw";
        my $time_before_dl = [gettimeofday];
        eval {
                local $SIG{ALRM} = sub {die "timeout\n"};
                alarm 1;
                $mirrored_SHA256 = download($url, "SHA256");
                alarm 0;
        };
        if ($@) {
                die unless $@ eq "timeout\n";
                next;
        } else {
                my $time = tv_interval $time_before_dl;
                if ( defined($mirrored_SHA256) and ($SHA256 eq $mirrored_SHA256)) {
                        $synced_mirror{$candidat_server} = $time;
                }
        }
}
print "Done\n";

my @sorted_mirrors = sort {$synced_mirror{$a} <=> $synced_mirror{$b}} keys %synced_mirror;
die "No synchronised mirror found, try later..." if $#sorted_mirrors == -1;

MIRROR: {
        print "Mirror? (or 'list') [$sorted_mirrors[0]] ";
        chomp(my $line = <STDIN>);
        if ($line eq "list") {
                print "Synchronised mirrors from fastest to slowest:\n";
                for (@sorted_mirrors) {
                        print "    $_\n";
                }
                redo MIRROR;
        } elsif ($line eq "") {
                $server = $sorted_mirrors[0];
                last MIRROR;
        } elsif ((grep {/^$line$/} @sorted_mirrors) == 1) {
                $server = $line;
                last MIRROR;
        } else {
                print "Bad mirror string '$line'\n";
                redo MIRROR;
        }
}


my $checked_set_pattern = "^INSTALL|^bsd|tgz\$";
my %sets; # {$set => $status} ; $set = "bsd" ; $status = "checked"

for (split /\n/s, $SHA256) {
        my $set = (/\((.*)\)/) ? $1 : die "Weird SHA256\n";
        my $status = ($set =~ $checked_set_pattern) ? "checked" : "not checked";
        $sets{$set} = $status;
}

SETS: {
        print "Sets available:\n";
	my @sets;
        for (sort keys %sets) {
		my $box = ($sets{$_} eq "checked") ? "[x]" : "[ ]";
		push @sets, "$box $_";
        }
	format_check(\@sets);
        printf "Set names? (or 'done') [done] ";
        chomp(my $line = <STDIN>);
        my $operation;
        my $pattern;
        if ($line eq "done" or $line eq "") {
                last SETS;
        } else {
                if ($line =~ /(\+|-)(.+)/) {
                        $operation = $1;
                        $pattern = $2;
			if($pattern =~ /\*/) {
				print "pattern '*' not allowed\n";
				redo SETS;
			}
                } else {
                        print "+re add sets with pattern re\n-re remove sets with pattern re\n";
                        redo SETS;
                        
                }
                for my $set (sort keys %sets) {
                        if ($set =~ /$pattern/
                            && $operation eq '-') {
                                $sets{$set} = "not checked";
                        } elsif ($set =~ /$pattern/
                            && $operation eq '+') {
                                $sets{$set} = "checked";
                        }
                }
                redo SETS;
        }
}


print "OK let's get the sets from $server!\n";

my @stripped_SHA256; #SHA256 stripped from undownloaded sets

if ($pretend eq "yes") {
        print "Pretending:\n";
}

for my $set (sort keys %sets) {
        if ($sets{$set} eq "checked"
            && $SHA256 =~ /(SHA256 \($set\) = [a-f0-9]+\n)/s) {
                if ($pretend eq "no") {
                        download_and_save("$server/$openbsd_ver/$hw", "$set");
			if($set =~ /^base/) {
				$base_set = $set;
			} elsif($set =~ /^xbase/) {
				$xbase_set = $set;
			}
			if ( defined $1 ) {
				push @stripped_SHA256, $1 . "\n";
			}
                } else {
                        print "ftp -r 1 $server/$openbsd_ver/$hw/$set\n";
                }
        }
}
my $str_index_txt = download("$server/$openbsd_ver/$hw", "index.txt");

if ($pretend eq "no") {
        open my $fh_SHA256, '>', 'SHA256' or die $!;
	chomp(@stripped_SHA256);
        print $fh_SHA256 @stripped_SHA256;
        close $fh_SHA256;
        print "Checksum:\n";
        open $fh_SHA256, '<', "SHA256" or die "can't open SHA256";
        while (my $line_SHA = <$fh_SHA256>) {
		chomp($line_SHA);
		my @a_line_SHA = split / /, $line_SHA;
		# Filename is in second position
		my $ifile = $a_line_SHA[1];
		$ifile =~ s/\(|\)//g;

		if ( -f ($sets_dir . "/" . $ifile) ) {
			my $ck_line = cksum256($sets_dir . "/" . $ifile);
			if ($line_SHA ne $ck_line) {
				die "Bad checksum in $ifile";
			} else {
				print $ifile . " : OK\n";
			}
		} else {
			print($sets_dir . "/" . $ifile . " not found\n");
		}
        }
        close $fh_SHA256;
        open my $fh_index_txt, '>', 'index.txt' or die $!;
        print $fh_index_txt $str_index_txt;
	close $fh_index_txt;
	open my $fh_SHA256sig, '>', 'SHA256.sig' or die $!;
	print $fh_SHA256sig $SHA256sig;
	close $fh_SHA256sig;

	wantlib_check;
}
