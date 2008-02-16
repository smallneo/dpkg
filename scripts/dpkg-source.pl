#! /usr/bin/perl

use strict;
use warnings;

use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling qw(warning warnerror error failure unknown
                           internerr syserr subprocerr usageerr
                           $warnable_error $quiet_warnings);
use Dpkg::Arch qw(debarch_eq);
use Dpkg::Deps qw(@src_dep_fields %dep_field_type);
use Dpkg::Fields qw(:list capit);
use Dpkg::Compression;
use Dpkg::Cdata;
use Dpkg::Control;
use Dpkg::Substvars;
use Dpkg::Version qw(check_version);
use Dpkg::Vars;
use Dpkg::Changelog qw(parse_changelog);
use Dpkg::Source::Compressor;
use Dpkg::Source::Archiver;

my @filesinarchive;
my %dirincluded;
my %notfileobject;
my $fn;
my $ur;

my $varlistfile;
my $controlfile;
my $changelogfile;
my $changelogformat;

our $diff_ignore_regexp = '';
my $diff_ignore_default_regexp = '
# Ignore general backup files
(?:^|/).*~$|
# Ignore emacs recovery files
(?:^|/)\.#.*$|
# Ignore vi swap files
(?:^|/)\..*\.swp$|
# Ignore baz-style junk files or directories
(?:^|/),,.*(?:$|/.*$)|
# File-names that should be ignored (never directories)
(?:^|/)(?:DEADJOE|\.cvsignore|\.arch-inventory|\.bzrignore|\.gitignore)$|
# File or directory names that should be ignored
(?:^|/)(?:CVS|RCS|\.deps|\{arch\}|\.arch-ids|\.svn|\.hg|_darcs|\.git|
\.shelf|_MTN|\.bzr(?:\.backup|tags)?)(?:$|/.*$)
';
# Take out comments and newlines
$diff_ignore_default_regexp =~ s/^#.*$//mg;
$diff_ignore_default_regexp =~ s/\n//sg;

no warnings 'qw';
my @tar_ignore_default_pattern = qw(
*.a
*.la
*.o
*.so
*.swp
*~
,,*
.[#~]*
.arch-ids
.arch-inventory
.bzr
.bzr.backup
.bzr.tags
.bzrignore
.cvsignore
.deps
.git
.gitignore
.hg
.shelf
.svn
CVS
DEADJOE
RCS
_MTN
_darcs
{arch}
);

my $sourcestyle = 'X';
my $min_dscformat = 1;
my $max_dscformat = 3;
my $def_dscformat = "1.0"; # default format for -b

my $expectprefix;

# Compression
my $compression = 'gzip';
my $comp_level = '9';
my $comp_ext = $comp_ext{$compression};

# Packages
my %remove;
my %override;

# Files
my %md5sum;
my %size;
my %type;		 # used by checktype
my %filepatched;	 # used by checkdiff
my %dirtocreate;	 # used by checkdiff

my @tar_ignore;

my $substvars = Dpkg::Substvars->new();
my $compressor = Dpkg::Source::Compressor->new();

use POSIX;
use Fcntl qw (:mode);
use English;
use File::Temp qw (tempfile);

textdomain("dpkg-dev");

my @dsc_fields = (qw(Format Source Binary Architecture Version Origin
		     Maintainer Uploaders Dm-Upload-Allowed Homepage
		     Standards-Version Vcs-Browser Vcs-Arch Vcs-Bzr
		     Vcs-Cvs Vcs-Darcs Vcs-Git Vcs-Hg Vcs-Mtn Vcs-Svn),
                  @src_dep_fields);


# Make sure patch doesn't get any funny ideas
delete $ENV{'POSIXLY_CORRECT'};

my @exit_handlers = ();
sub exit_handler {
	&$_ foreach ( reverse @exit_handlers );
	exit(127);
}
$SIG{'INT'} = \&exit_handler;
$SIG{'HUP'} = \&exit_handler;
$SIG{'QUIT'} = \&exit_handler;

sub version {
    printf _g("Debian %s version %s.\n"), $progname, $version;

    print _g("
Copyright (C) 1996 Ian Jackson and Klee Dienes.");

    print _g("
This is free software; see the GNU General Public Licence version 2 or
later for copying conditions. There is NO warranty.
");
}

sub usage {
    printf _g(
"Usage: %s [<option> ...] <command>

Commands:
  -x <filename>.dsc [<output-dir>]
                           extract source package.
  -b <dir> [<orig-dir>|<orig-targz>|\'\']
                           build source package.

Build options:
  -c<controlfile>          get control info from this file.
  -l<changelogfile>        get per-version info from this file.
  -F<changelogformat>      force change log format.
  -V<name>=<value>         set a substitution variable.
  -T<varlistfile>          read variables here, not debian/substvars.
  -D<field>=<value>        override or add a .dsc field and value.
  -U<field>                remove a field.
  -E                       turn certain warnings into errors.
  -W                       when -E is enabled, -W disables it.
  -q                       quiet operation, do not print warnings.
  -i[<regexp>]             filter out files to ignore diffs of
                             (defaults to: '%s').
  -I[<pattern>]            filter out files when building tarballs
                             (defaults to: %s).
  -sa                      auto select orig source (-sA is default).
  -sk                      use packed orig source (unpack & keep).
  -sp                      use packed orig source (unpack & remove).
  -su                      use unpacked orig source (pack & keep).
  -sr                      use unpacked orig source (pack & remove).
  -ss                      trust packed & unpacked orig src are same.
  -sn                      there is no diff, do main tarfile only.
  -sA,-sK,-sP,-sU,-sR      like -sa,-sk,-sp,-su,-sr but may overwrite.
  -Z<compression>          select compression to use (defaults to 'gzip',
                             supported are: %s).
  -z<level>                compression level to use (defaults to '9',
                             supported are: '1'-'9', 'best', 'fast')

Extract options:
  -sp (default)            leave orig source packed in current dir.
  -sn                      do not copy original source to current dir.
  -su                      unpack original source tree too.

General options:
  -h, --help               show this help message.
      --version            show the version.
"), $progname,
    $diff_ignore_default_regexp,
    join('', map { " -I$_" } @tar_ignore_default_pattern),
    "@comp_supported" ;
}

sub handleformat {
	my $fmt = shift;
	return unless $fmt =~ /^(\d+)/; # only check major version
	return $1 >= $min_dscformat && $1 <= $max_dscformat;
}

sub loadvcs {
	my $vcs = shift;
	my $mod = "Dpkg::Source::VCS::$vcs";
	eval qq{require $mod};
	return if $@;
	return import $mod;
}


my $opmode;
my $tar_ignore_default_pattern_done;

while (@ARGV && $ARGV[0] =~ m/^-/) {
    $_=shift(@ARGV);
    if (m/^-b$/) {
        &setopmode('build');
    } elsif (m/^-x$/) {
        &setopmode('extract');
    } elsif (m/^-Z/) {
	$compression = $POSTMATCH;
	$comp_ext = $comp_ext{$compression};
	usageerr(_g("%s is not a supported compression"), $compression)
	    unless $comp_supported{$compression};
    } elsif (m/^-z/) {
	$comp_level = $POSTMATCH;
	usageerr(_g("%s is not a compression level"), $comp_level)
	    unless $comp_level =~ /^([1-9]|fast|best)$/;
    } elsif (m/^-s([akpursnAKPUR])$/) {
	warning(_g("-s%s option overrides earlier -s%s option"), $1, $sourcestyle)
	    if $sourcestyle ne 'X';
        $sourcestyle= $1;
    } elsif (m/^-c/) {
        $controlfile= $POSTMATCH;
    } elsif (m/^-l/) {
        $changelogfile= $POSTMATCH;
    } elsif (m/^-F([0-9a-z]+)$/) {
        $changelogformat=$1;
    } elsif (m/^-D([^\=:]+)[=:]/) {
        $override{$1}= $POSTMATCH;
    } elsif (m/^-U([^\=:]+)$/) {
        $remove{$1}= 1;
    } elsif (m/^-i(.*)$/) {
        $diff_ignore_regexp = $1 ? $1 : $diff_ignore_default_regexp;
    } elsif (m/^-I(.+)$/) {
        push @tar_ignore, "--exclude=$1";
    } elsif (m/^-I$/) {
        unless ($tar_ignore_default_pattern_done) {
            push @tar_ignore,
                 map { "--exclude=$_" } @tar_ignore_default_pattern;
            # Prevent adding multiple times
            $tar_ignore_default_pattern_done = 1;
        }
    } elsif (m/^-V(\w[-:0-9A-Za-z]*)[=:]/) {
        $substvars->set($1, $POSTMATCH);
    } elsif (m/^-T/) {
	$varlistfile = $POSTMATCH;
	warning(_g("substvars support is deprecated (see README.feature-removal-schedule)"));
    } elsif (m/^-(h|-help)$/) {
        &usage; exit(0);
    } elsif (m/^--version$/) {
        &version; exit(0);
    } elsif (m/^-W$/) {
        $warnable_error= 1;
    } elsif (m/^-E$/) {
        $warnable_error= 0;
    } elsif (m/^-q$/) {
        $quiet_warnings = 1;
    } elsif (m/^--$/) {
        last;
    } else {
        usageerr(_g("unknown option \`%s'"), $_);
    }
}

defined($opmode) || &usageerr(_g("need -x or -b"));

$SIG{'PIPE'} = 'DEFAULT';

if ($opmode eq 'build') {

    @ARGV || &usageerr(_g("-b needs a directory"));
    @ARGV<=2 || &usageerr(_g("-b takes at most a directory and an orig source argument"));
    my $dir = shift(@ARGV);
    $dir= "./$dir" unless $dir =~ m:^/:; $dir =~ s,/*$,,;
    stat($dir) || error(_g("cannot stat directory %s: %s"), $dir, $!);
    -d $dir || error(_g("directory argument %s is not a directory"), $dir);

    $changelogfile= "$dir/debian/changelog" unless defined($changelogfile);
    $controlfile= "$dir/debian/control" unless defined($controlfile);
    
    my %options = (file => $changelogfile);
    $options{"changelogformat"} = $changelogformat if $changelogformat;
    my $changelog = parse_changelog(%options);
    my $control = Dpkg::Control->new($controlfile);
    my $fields = Dpkg::Fields::Object->new();

    $fields->{"Format"} = $compression eq 'gzip' ? $def_dscformat : '2.0';

    my @sourcearch;
    my %archadded;
    my $archspecific = 0; # XXX: Not used?!
    my @binarypackages;

    # Scan control info of source package
    my $src_fields = $control->get_source();
    foreach $_ (keys %{$src_fields}) {
	my $v = $src_fields->{$_};
	if (m/^Source$/i) {
	    set_source_package($v);
	} elsif (m/^(Format|Standards-Version|Origin|Maintainer|Homepage)$/i ||
		 m/^Dm-Upload-Allowed$/i ||
		 m/^Vcs-(Browser|Arch|Bzr|Cvs|Darcs|Git|Hg|Mtn|Svn)$/i) {
	    $fields->{$_} = $v;
	} elsif (m/^Uploaders$/i) {
	    ($fields->{$_} = $v) =~ s/[\r\n]//g; # Merge in a single-line
	} elsif (m/^Build-(Depends|Conflicts)(-Indep)?$/i) {
	    my $dep;
	    my $type = $dep_field_type{capit($_)};
	    $dep = Dpkg::Deps::parse($v, union =>  $type eq 'union');
	    error(_g("error occurred while parsing %s"), $_) unless defined $dep;
	    my $facts = Dpkg::Deps::KnownFacts->new();
	    $dep->simplify_deps($facts);
	    $dep->sort();
	    $fields->{$_} = $dep->dump();
	} elsif (s/^X[BC]*S[BC]*-//i) { # Include XS-* fields
	    $fields->{$_} = $v;
	} elsif (m/^$control_src_field_regex$/i || m/^X[BC]+-/i) {
	    # Silently ignore valid fields
	} else {
	    unknown(_g('general section of control info file'));
	}
    }

    # Scan control info of binary packages
    foreach my $pkg ($control->get_packages()) {
	my $p = $pkg->{'Package'};
	push(@binarypackages,$p);
	foreach $_ (keys %{$pkg}) {
	    my $v = $pkg->{$_};
            if (m/^Architecture$/) {
		if (debarch_eq($v, 'any')) {
                    @sourcearch= ('any');
		} elsif (debarch_eq($v, 'all')) {
                    if (!@sourcearch || $sourcearch[0] eq 'all') {
                        @sourcearch= ('all');
                    } else {
                        @sourcearch= ('any');
                    }
                } else {
		    if (@sourcearch && grep($sourcearch[0] eq $_, 'any', 'all')) {
			@sourcearch= ('any');
		    } else {
			for my $a (split(/\s+/, $v)) {
			    error(_g("`%s' is not a legal architecture string"),
			          $a)
				unless $a =~ /^[\w-]+$/;
			    error(_g("architecture %s only allowed on its " .
			             "own (list for package %s is `%s')"),
			          $a, $p, $a)
				if grep($a eq $_, 'any','all');
                            push(@sourcearch,$a) unless $archadded{$a}++;
                        }
                }
                }
                $fields->{'Architecture'}= join(' ',@sourcearch);
            } elsif (s/^X[BC]*S[BC]*-//i) { # Include XS-* fields
                $fields->{$_} = $v;
            } elsif (m/^$control_pkg_field_regex$/ ||
                     m/^X[BC]+-/i) { # Silently ignore valid fields
            } else {
                unknown(_g("package's section of control info file"));
            }
	}
    }

    # Scan fields of dpkg-parsechangelog
    foreach $_ (keys %{$changelog}) {
        my $v = $changelog->{$_};

	if (m/^Source$/) {
	    set_source_package($v);
	} elsif (m/^Version$/) {
	    check_version($v);
	    $fields->{$_} = $v;
	} elsif (s/^X[BS]*C[BS]*-//i) {
	    $fields->{$_} = $v;
	} elsif (m/^(Maintainer|Changes|Urgency|Distribution|Date|Closes)$/i ||
		 m/^X[BS]+-/i) {
	} else {
	    unknown(_g("parsed version of changelog"));
	}
    }
    
    my $vcs;
    if ($fields->{Format} =~ /^\s*(\d+\.\d+)\s*$/) {
	    if ($1 >= 3.0) {
		error(_g("don't know how to generate %s format source package (missing vcs specifier in Format field?)"),
		      $1);
	    }
	    if ($1 > 1.0) {
		error(_g("don't know how to generate %s format source package"),
		      $1);
	    }
    }
    elsif ($fields->{Format} =~ /^\s*(\d+(?:\.\d+)?)\s+\((\w+)\)\s*$/) {
	    $fields->{Format} = $1;
	    if ($1 < 3.0) {
		error(_g("control info file 'Format' field for version %s does not support vcs specifier \"%s\""),
		      $1, $2);
	    }
	    if ($1 >= 4) {
		error(_g("unsupported control info file 'Format' value \"%s\""),
		      $1);
	    }

	    $vcs = $2;
	    loadvcs($2)
		|| error(_g("unsupported vcs \"%s\" in control info file 'Format' field"), $2);

	    if ($sourcestyle =~ /[akpursKPUR]/) {
		warning(_g("source handling style -s%s not supported when generating %s format source package"),
			$sourcestyle, $vcs);
	    }
	    $sourcestyle = 'v';
    }
    
    $sourcestyle =~ y/X/A/;
    $sourcestyle =~ m/[akpursnAKPURv]/ ||
        usageerr(_g("source handling style -s%s not allowed with -b"),
		$sourcestyle);

    $fields->{'Binary'}= join(', ', @binarypackages);
    foreach my $f (keys %override) {
	$fields->{$f} = $override{$f};
    }

    for my $f (qw(Version)) {
	defined($fields->{$f}) ||
	    error(_g("missing information for critical output field %s"), $f);
    }
    for my $f (qw(Maintainer Architecture Standards-Version)) {
	defined($fields->{$f}) ||
	    warning(_g("missing information for output field %s"), $f);
    }
    defined($sourcepackage) || &error(_g("unable to determine source package name !"));
    $fields->{'Source'} = $sourcepackage;
    for my $f (keys %remove) {
	delete $fields->{$f};
    }

    my $version = $fields->{'Version'};
    $version =~ s/^\d+://;
    my $upstreamversion = $version;
    $upstreamversion =~ s/-[^-]*$//;
    my $basenamerev = $sourcepackage.'_'.$version;
    my $basename = $sourcepackage.'_'.$upstreamversion;
    my $basedirname = $basename;
    $basedirname =~ s/_/-/;

    my $origdir = "$dir.orig";
    my $origtargz;
    # Try to find a .orig tarball for the package
    my @origtargz = map { "$basename.orig.tar.$comp_ext{$_}" } ($compression, @comp_supported);
    foreach my $origtar (@origtargz) {
	if (stat($origtar)) {
	    -f _ || error(_g("packed orig `%s' exists but is not a plain file"),
			  $origtar);
	    $origtargz = $origtar;
	    last;
	} elsif ($! != ENOENT) {
	    syserr(_g("unable to stat putative packed orig `%s'"), $origtar);
	}
    }

    if (@ARGV) {
	# We have a second-argument <orig-dir> or <orig-targz>, check what it
	# is to decide the mode to use
        my $origarg = shift(@ARGV);
        if (length($origarg)) {
            stat($origarg) ||
                error(_g("cannot stat orig argument %s: %s"), $origarg, $!);
            if (-d _) {
                $origdir= $origarg;
                $origdir= "./$origdir" unless $origdir =~ m,^/,; $origdir =~ s,/*$,,;
                $sourcestyle =~ y/aA/rR/;
                $sourcestyle =~ m/[ursURS]/ ||
                    error(_g("orig argument is unpacked but source handling " .
                             "style -s%s calls for packed (.orig.tar.<ext>)"),
                          $sourcestyle);
            } elsif (-f _) {
                $origtargz= $origarg;
                $sourcestyle =~ y/aA/pP/;
                $sourcestyle =~ m/[kpsKPS]/ ||
                    error(_g("orig argument is packed but source handling " .
                             "style -s%s calls for unpacked (.orig/)"),
                          $sourcestyle);
            } else {
                &error("orig argument $origarg is not a plain file or directory");
            }
        } else {
            $sourcestyle =~ y/aA/nn/;
            $sourcestyle =~ m/n/ ||
                error(_g("orig argument is empty (means no orig, no diff) " .
                         "but source handling style -s%s wants something"),
                      $sourcestyle);
        }
    } elsif ($sourcestyle =~ m/[aA]/) {
	# We have no explicit <orig-dir> or <orig-targz>, try to use
	# a .orig tarball first, then a .orig directory and fall back to
	# creating a native .tar.gz
	if ($origtargz) {
	    $sourcestyle =~ y/aA/pP/; # .orig.tar.<ext>
	} else {
	    if (stat($origdir)) {
		-d _ || error(_g("unpacked orig `%s' exists but is not a directory"),
		              $origdir);
		$sourcestyle =~ y/aA/rR/; # .orig directory
	    } elsif ($! != ENOENT) {
		syserr(_g("unable to stat putative unpacked orig `%s'"), $origdir);
	    } else {
		$sourcestyle =~ y/aA/nn/; # Native tar.gz
	    }
	}
    }

    my $dirbase = $dir;
    $dirbase =~ s,/?$,,;
    $dirbase =~ s,[^/]+$,,;
    my $dirname = $&;
    $dirname eq $basedirname ||
	warning(_g("source directory '%s' is not <sourcepackage>" .
	           "-<upstreamversion> '%s'"), $dir, $basedirname);

    my $tarname;
    my $tardirname;
    my $tardirbase;
    my $origdirname;

    if ($sourcestyle eq 'v') {
	$tarname="$basenamerev.$vcs.tar.gz";
        $tardirbase= $dirbase; $tardirname= "$dirbase/$tarname.tmp";

	eval qq{Dpkg::Source::VCS::${vcs}::prep_tar(\$dir, \$tardirname)};
	if ($@) {
	    failure($@);
	}
	push @exit_handlers, sub { erasedir($tardirname) };
    }
    elsif ($sourcestyle ne 'n') {
	my $origdirbase = $origdir;
	$origdirbase =~ s,/?$,,;
        $origdirbase =~ s,[^/]+$,,; $origdirname= $&;

        $origdirname eq "$basedirname.orig" ||
	    warning(_g(".orig directory name %s is not <package>" .
	               "-<upstreamversion> (wanted %s)"),
	            $origdirname, "$basedirname.orig");
        $tardirbase= $origdirbase; $tardirname= $origdirname;

	$tarname= $origtargz || "$basename.orig.tar.$comp_ext";
	if ($tarname =~ /\Q$basename\E\.orig\.tar\.($comp_regex)/) {
	    if (($1 ne 'gz') && ($fields->{'Format'} < 2)) { $fields->{'Format'} = '2.0' };
	} else {
	    warning(_g(".orig.tar name %s is not <package>_<upstreamversion>" .
	               ".orig.tar (wanted %s)"),
	            $tarname, "$basename.orig.tar.$comp_regex");
	}
    } else {
	$tardirbase= $dirbase; $tardirname= $dirname;
	$tarname= "$basenamerev.tar.$comp_ext";
    }

    if ($sourcestyle =~ m/[nurURv]/) {

        if (stat($tarname)) {
            $sourcestyle =~ m/[nURv]/ ||
		error(_g("tarfile `%s' already exists, not overwriting, " .
		         "giving up; use -sU or -sR to override"), $tarname);
        } elsif ($! != ENOENT) {
	    syserr(_g("unable to check for existence of `%s'"), $tarname);
        }

        printf(_g("%s: building %s in %s")."\n",
               $progname, $sourcepackage, $tarname);

	my ($ntfh, $newtar) = tempfile("$tarname.new.XXXXXX",
				       DIR => getcwd(), UNLINK => 0);
	my $tar = Dpkg::Source::Archiver->new(filename => $newtar,
		    compression => get_compression_from_filename($tarname));
	$tar->create(options => \@tar_ignore);
	$tar->add_directory($tardirname);
	$tar->close();
        rename($newtar, $tarname) ||
            syserr(_g("unable to rename `%s' (newly created) to `%s'"),
                   $newtar, $tarname);
	chmod(0666 &~ umask(), $tarname) ||
	    syserr(_g("unable to change permission of `%s'"), $tarname);

    } else {
        
        printf(_g("%s: building %s using existing %s")."\n",
               $progname, $sourcepackage, $tarname);

    }
    
    addfile($fields, "$tarname");

    if ($sourcestyle =~ m/[kpKP]/) {

        if (stat($origdir)) {
            $sourcestyle =~ m/[KP]/ ||
                error(_g("orig dir `%s' already exists, not overwriting, ".
                         "giving up; use -sA, -sK or -sP to override"),
                      $origdir);
	    push @exit_handlers, sub { erasedir($origdir) };
            erasedir($origdir);
	    pop @exit_handlers;
        } elsif ($! != ENOENT) {
             syserr(_g("unable to check for existence of orig dir `%s'"),
                    $origdir);
        }

        $expectprefix= $origdir; $expectprefix =~ s,^\./,,;
	my $tar = Dpkg::Source::Archiver->new(filename => $origtargz);
	$tar->extract($expectprefix);
    }

    if ($sourcestyle eq 'v') {
        erasedir($tardirname)
    }
        
    if ($sourcestyle =~ m/[kpursKPUR]/) {

	my $diffname = "$basenamerev.diff.$comp_ext";
        printf(_g("%s: building %s in %s")."\n",
               $progname, $sourcepackage, $diffname)
            || &syserr(_g("write building diff message"));
	my ($ndfh, $newdiffgz) = tempfile( "$diffname.new.XXXXXX",
					DIR => &getcwd, UNLINK => 0 );
        &forkgzipwrite($newdiffgz);

	defined(my $c2 = open(FIND, "-|")) || syserr(_g("fork for find"));
        if (!$c2) {
            chdir($dir) || syserr(_g("chdir to %s for find"), $dir);
            exec('find','.','-print0') or &syserr(_g("exec find"));
        }
        $/= "\0";

      file:
        while (defined($fn= <FIND>)) {
            $fn =~ s/\0$//;
            next file if $fn =~ m/$diff_ignore_regexp/o;
            $fn =~ s,^\./,,;
            lstat("$dir/$fn") || syserr(_g("cannot stat file %s"), "$dir/$fn");
	    my $mode = S_IMODE((lstat(_))[2]);
	    my $size = (lstat(_))[7];
            if (-l _) {
                $type{$fn}= 'symlink';
		checktype($origdir, $fn, '-l') || next;
		defined(my $n = readlink("$dir/$fn")) ||
                    syserr(_g("cannot read link %s"), "$dir/$fn");
		defined(my $n2 = readlink("$origdir/$fn")) ||
                    syserr(_g("cannot read orig link %s"), "$origdir/$fn");
                $n eq $n2 || &unrepdiff2(sprintf(_g("symlink to %s"), $n2),
                                         sprintf(_g("symlink to %s"), $n));
            } elsif (-f _) {
		my $ofnread;

                $type{$fn}= 'plain file';
                if (!lstat("$origdir/$fn")) {
                    $! == ENOENT ||
                        syserr(_g("cannot stat orig file %s"), "$origdir/$fn");
                    $ofnread= '/dev/null';
		    if( !$size ) {
			warning(_g("newly created empty file '%s' will not " .
			           "be represented in diff"), $fn);
		    } else {
			if( $mode & ( S_IXUSR | S_IXGRP | S_IXOTH ) ) {
			    warning(_g("executable mode %04o of '%s' will " .
			               "not be represented in diff"), $mode, $fn)
				unless $fn eq 'debian/rules';
			}
			if( $mode & ( S_ISUID | S_ISGID | S_ISVTX ) ) {
			    warning(_g("special mode %04o of '%s' will not " .
			               "be represented in diff"), $mode, $fn);
			}
		    }
                } elsif (-f _) {
                    $ofnread= "$origdir/$fn";
                } else {
                    &unrepdiff2(_g("something else"),
                                _g("plain file"));
                    next;
                }
		defined(my $c3 = open(DIFFGEN, "-|")) || syserr(_g("fork for diff"));
                if (!$c3) {
		    $ENV{'LC_ALL'}= 'C';
		    $ENV{'LANG'}= 'C';
		    $ENV{'TZ'}= 'UTC0';
		    my $tab = ("$basedirname/$fn" =~ / /) ? "\t" : '';
		    exec('diff','-u',
			 '-L',"$basedirname.orig/$fn$tab",
			 '-L',"$basedirname/$fn$tab",
			 '--',"$ofnread","$dir/$fn") or &syserr(_g("exec diff"));
                }
		my $difflinefound = 0;
                $/= "\n";
                while (<DIFFGEN>) {
                    if (m/^binary/i) {
                        close(DIFFGEN); $/= "\0";
                        &unrepdiff(_g("binary file contents changed"));
                        next file;
                    } elsif (m/^[-+\@ ]/) {
                        $difflinefound=1;
                    } elsif (m/^\\ No newline at end of file$/) {
			warning(_g("file %s has no final newline (either " .
			           "original or modified version)"), $fn);
                    } else {
                        s/\n$//;
			internerr(_g("unknown line from diff -u on %s: `%s'"),
			          $fn, $_);
                    }
		    print(GZIP $_) || &syserr(_g("failed to write to compression pipe"));
                }
                close(DIFFGEN); $/= "\0";
		my $es;
                if (WIFEXITED($?) && (($es=WEXITSTATUS($?))==0 || $es==1)) {
                    if ($es==1 && !$difflinefound) {
                        &unrepdiff(_g("diff gave 1 but no diff lines found"));
                    }
                } else {
		    subprocerr(_g("diff on %s"), "$dir/$fn");
                }
            } elsif (-p _) {
                $type{$fn}= 'pipe';
		checktype($origdir, $fn, '-p');
            } elsif (-b _ || -c _ || -S _) {
                &unrepdiff(_g("device or socket is not allowed"));
            } elsif (-d _) {
                $type{$fn}= 'directory';
		if (!lstat("$origdir/$fn")) {
		    $! == ENOENT ||
		        syserr(_g("cannot stat orig file %s"), "$origdir/$fn");
		} elsif (! -d _) {
		    &unrepdiff2(_g('not a directory'),
		                _g('directory'));
		}
            } else {
                &unrepdiff(sprintf(_g("unknown file type (%s)"), $!));
            }
        }
        close(FIND); $? && subprocerr("find on $dir");
	close(GZIP) || &syserr(_g("finish write to compression pipe"));
        &reapgzip;
	rename($newdiffgz, $diffname) ||
	    syserr(_g("unable to rename `%s' (newly created) to `%s'"),
	           $newdiffgz, $diffname);
	chmod(0666 &~ umask(), $diffname) ||
	    syserr(_g("unable to change permission of `%s'"), $diffname);

        defined($c2= open(FIND,"-|")) || &syserr(_g("fork for 2nd find"));
        if (!$c2) {
            chdir($origdir) || syserr(_g("chdir to %s for 2nd find"), $origdir);
            exec('find','.','-print0') or &syserr(_g("exec 2nd find"));
        }
        $/= "\0";
        while (defined($fn= <FIND>)) {
            $fn =~ s/\0$//;
            next if $fn =~ m/$diff_ignore_regexp/o;
            $fn =~ s,^\./,,;
            next if defined($type{$fn});
            lstat("$origdir/$fn") ||
                syserr(_g("cannot check orig file %s"), "$origdir/$fn");
            if (-f _) {
		warning(_g("ignoring deletion of file %s"), $fn);
            } elsif (-d _) {
		warning(_g("ignoring deletion of directory %s"), $fn);
            } elsif (-l _) {
		warning(_g("ignoring deletion of symlink %s"), $fn);
            } else {
                &unrepdiff2(_g('not a file, directory or link'),
                            _g('nonexistent'));
            }
        }
        close(FIND); $? && subprocerr("find on $dirname");

	addfile($fields, $diffname);

    }

    if ($sourcestyle =~ m/[prPR]/) {
        erasedir($origdir);
    }

    printf(_g("%s: building %s in %s")."\n",
           $progname, $sourcepackage, "$basenamerev.dsc")
        || &syserr(_g("write building message"));
    open(DSC, ">", "$basenamerev.dsc") ||
        syserr(_g("create %s"), "$basenamerev.dsc");

    $substvars->parse($varlistfile) if $varlistfile && -e $varlistfile;
    tied(%{$fields})->set_field_importance(@dsc_fields);
    tied(%{$fields})->output(\*DSC, $substvars);
    close(DSC);

    if ($ur) {
        printf(STDERR _g("%s: unrepresentable changes to source")."\n",
               $progname) || syserr(_g("write error msg: %s"), $!);
        exit(1);
    }
    exit(0);

} else { # -> opmode ne 'build'

    $sourcestyle =~ y/X/p/;
    $sourcestyle =~ m/[pun]/ ||
	usageerr(_g("source handling style -s%s not allowed with -x"),
	         $sourcestyle);

    @ARGV>=1 || &usageerr(_g("-x needs at least one argument, the .dsc"));
    @ARGV<=2 || &usageerr(_g("-x takes no more than two arguments"));
    my $dsc = shift(@ARGV);
    $dsc= "./$dsc" unless $dsc =~ m:^/:;
    ! -d $dsc
	|| &usageerr(_g("-x needs the .dsc file as first argument, not a directory"));
    my $dscdir = $dsc;
    $dscdir = "./$dscdir" unless $dsc =~ m,^/|^\./,;
    $dscdir =~ s,/[^/]+$,,;

    my $newdirectory;
    if (@ARGV) {
	$newdirectory= shift(@ARGV);
	! -e $newdirectory || error(_g("unpack target exists: %s"), $newdirectory);
    }

    my $is_signed = 0;
    open(DSC, "<", $dsc) || error(_g("cannot open .dsc file %s: %s"), $dsc, $!);
    while (<DSC>) {
	next if /^\s*$/o;
	$is_signed = 1 if /^-----BEGIN PGP SIGNED MESSAGE-----$/o;
	last;
    }
    close(DSC);

    if ($is_signed) {
	if (-x '/usr/bin/gpg') {
	    my $gpg_command = 'gpg -q --verify ';
	    if (-r '/usr/share/keyrings/debian-keyring.gpg') {
		$gpg_command = $gpg_command.'--keyring /usr/share/keyrings/debian-keyring.gpg ';
	    }
	    $gpg_command = $gpg_command.quotemeta($dsc).' 2>&1';

	    my @gpg_output = `$gpg_command`;
	    my $gpg_status = $? >> 8;
	    if ($gpg_status) {
		print STDERR join("",@gpg_output);
		error(_g("failed to verify signature on %s"), $dsc)
		    if ($gpg_status == 1);
	    }
	} else {
	    warning(_g("could not verify signature on %s since gpg isn't installed"),
	            $dsc);
	}
    } else {
	warning(_g("extracting unsigned source package (%s)"), $dsc);
    }

    open(CDATA, "<", $dsc) || error(_g("cannot open .dsc file %s: %s"), $dsc, $!);
    my $fields = parsecdata(\*CDATA, sprintf(_g("source control file %s"), $dsc),
			    allow_pgp => 1);
    close(CDATA);

    for my $f (qw(Source Version Files)) {
        defined($fields->{$f}) ||
            error(_g("missing critical source control field %s"), $f);
    }

    my $dscformat = $def_dscformat;
    if (defined $fields->{'Format'}) {
	if (not handleformat($fields->{'Format'})) {
	    error(_g("Unsupported format of .dsc file (%s)"), $fields->{'Format'});
	}
        $dscformat=$fields->{'Format'};
    }

    set_source_package($fields->{'Source'});

    my $version = $fields->{'Version'};
    my $baseversion;
    my $revision;

    check_version($version);
    $version =~ s/^\d+://;
    if ($version =~ m/-([^-]+)$/) {
        $baseversion= $`; $revision= $1;
    } else {
        $baseversion= $version; $revision= '';
    }

    my $files = $fields->{'Files'};
    my @tarfiles;
    my $difffile;
    my $debianfile;
    my %vcsfiles;
    my %seen;
    for my $file (split(/\n /, $files)) {
        next if $file eq '';
        $file =~ m/^([0-9a-f]{32})[ \t]+(\d+)[ \t]+([0-9a-zA-Z][-+:.,=0-9a-zA-Z_~]+)$/
            || error(_g("Files field contains bad line `%s'"), $file);
        ($md5sum{$3},$size{$3},$file) = ($1,$2,$3);
	local $_ = $file;

	error(_g("Files field contains invalid filename `%s'"), $file)
	    unless s/^\Q$sourcepackage\E_\Q$baseversion\E(?=[.-])// and
		   s/\.$comp_regex$//;
	s/^-\Q$revision\E(?=\.)// if length $revision;

	error(_g("repeated file type - files `%s' and `%s'"), $seen{$_}, $file)
	    if $seen{$_};
	$seen{$_} = $file;

	checkstats($dscdir, $file);

	if (/^\.(?:orig(-\w+)?\.)?tar$/) {
	    if ($1) { push @tarfiles, $file; } # push orig-foo.tar.gz to the end
	    else    { unshift @tarfiles, $file; }
	} elsif (/^\.debian\.tar$/) {
	    $debianfile = $file;
	} elsif (/^\.(\w+)\.tar$/) {
            my $vcs=$1;
            # TODO try to load vcs module
            push @tarfiles, $file;
            $vcsfiles{$file}=$vcs;
	} elsif (/^\.diff$/) {
	    $difffile = $file;
	} else {
	    error(_g("unrecognised file type - `%s'"), $file);
	}
    }

    &error(_g("no tarfile in Files field")) unless @tarfiles;
    my $native = !($difffile || $debianfile);
    if ($native) {
	warning(_g("multiple tarfiles in native package")) if @tarfiles > 1;
	warning(_g("native package with .orig.tar"))
	    unless $seen{'.tar'} or $seen{"-$revision.tar"} or %vcsfiles;
    } else {
	warning(_g("no upstream tarfile in Files field"))
	    unless $seen{'.orig.tar'} or %vcsfiles;
	if ($dscformat =~ /^1\./) {
	    warning(_g("multiple upstream tarballs in %s format dsc"), $dscformat)
	        if @tarfiles > 1;
	    warning(_g("debian.tar in %s format dsc"), $dscformat)
	        if $debianfile;
	}
    }
    if (%vcsfiles && $dscformat !~ /^3\./) {
	warning(sprintf(_g("<rc>.tar file in %s format dsc"), $dscformat));
    }

    $newdirectory = $sourcepackage.'-'.$baseversion unless defined($newdirectory);
    $expectprefix = $newdirectory;
    $expectprefix .= '.orig' if $difffile || $debianfile;
    
    checkdiff("$dscdir/$difffile") if $difffile;
    printf(_g("%s: extracting %s in %s")."\n",
           $progname, $sourcepackage, $newdirectory)
        || &syserr(_g("write extracting message"));
    
    &erasedir($newdirectory);
    ! -e "$expectprefix"
	|| rename("$expectprefix","$newdirectory.tmp-keep")
	|| syserr(_g("unable to rename `%s' to `%s'"), $expectprefix, "$newdirectory.tmp-keep");

    push @tarfiles, $debianfile if $debianfile;
    for my $tarfile (@tarfiles)
    {
	my $target;
	if ($tarfile =~ /\.orig-(\w+)\.tar/) {
	    my $sub = $1;
	    $sub =~ s/\d+$// if $sub =~ /\D/;
	    $target = "$expectprefix/$sub";
	} elsif ($tarfile =~ /\.debian\.tar/) {
	    $target = "$expectprefix/debian";
	} else {
	    $target = $expectprefix;
	}

	printf(_g("%s: unpacking %s")."\n", $progname, $tarfile);
	my $tar = Dpkg::Source::Archiver->new(filename => "$dscdir/$tarfile");
	$tar->extract($target);

	# for the first tar file:
	if ($tarfile eq $tarfiles[0] and !$native)
	{
	    # -sp: copy the .orig.tar.gz if required
	    if ($sourcestyle =~ /p/) {
		stat("$dscdir/$tarfile") ||
		    syserr(_g("failed to stat `%s' to see if need to copy"),
		           "$dscdir/$tarfile");

		my ($dsctardev, $dsctarino) = stat _;
		my $copy_required;

		if (stat($tarfile)) {
		    my ($dumptardev, $dumptarino) = stat _;
		    $copy_required = ($dumptardev != $dsctardev ||
		                      $dumptarino != $dsctarino);
		} else {
		    $! == ENOENT ||
			syserr(_g("failed to check destination `%s' " .
			          "to see if need to copy"), $tarfile);
		    $copy_required = 1;
		}

		if ($copy_required) {
		    system('cp','--',"$dscdir/$tarfile", $tarfile);
		    $? && subprocerr("cp $dscdir/$tarfile to $tarfile");
		}
	    }
	    # -su: keep .orig directory unpacked
	    elsif ($sourcestyle =~ /u/ and $expectprefix ne $newdirectory) {
		! -e "$newdirectory.tmp-keep"
		    || &error(_g("unable to keep orig directory (already exists)"));
		system('cp','-ar','--',$expectprefix,"$newdirectory.tmp-keep");
		$? && subprocerr("cp $expectprefix to $newdirectory.tmp-keep");
	    }
	}

        if (exists $vcsfiles{$tarfile}) {
	    printf(_g("%s: extracting source from %s repository")."\n", $progname, $vcsfiles{$tarfile});
	    loadvcs($vcsfiles{$tarfile})
	    	|| error(sprintf(_g("unsupported vcs \"%s\""), $vcsfiles{$tarfile}));
	    eval qq{Dpkg::Source::VCS::$vcsfiles{$tarfile}::post_unpack_tar(\$target)};
	    if ($@) {
                &syserr($@);
	    }
        }
    }

    my @patches;
    push @patches, "$dscdir/$difffile" if $difffile;

    if ($debianfile and -d (my $pd = "$expectprefix/debian/patches"))
    {
	my @p;

	opendir D, $pd;
	while (defined ($_ = readdir D))
	{
	    # patches match same rules as run-parts
	    next unless /^[\w-]+$/ and -f "$pd/$_";
	    my $p = $_;
	    checkdiff("$pd/$p");
	    push @p, $p;
	}

	closedir D;

	push @patches, map "$newdirectory/debian/patches/$_", sort @p;
    }

    for my $dircreate (keys %dirtocreate) {
	my $dircreatem = "";
	for my $dircreatep (split("/", $dircreate)) {
	    $dircreatem .= $dircreatep . "/";
	    if (!lstat($dircreatem)) {
		$! == ENOENT || syserr(_g("cannot stat %s"), $dircreatem);
		mkdir($dircreatem,0777)
		    || syserr(_g("failed to create %s subdirectory"), $dircreatem);
	    }
	    else {
		-d _ || error(_g("diff patches file in directory `%s', " .
		                 "but %s isn't a directory !"),
		              $dircreate, $dircreatem);
	    }
	}
    }

    if ($newdirectory ne $expectprefix)
    {
	rename($expectprefix,$newdirectory) ||
	    syserr(_g("failed to rename newly-extracted %s to %s"),
	           $expectprefix, $newdirectory);

	# rename the copied .orig directory
	! -e "$newdirectory.tmp-keep"
	    || rename("$newdirectory.tmp-keep",$expectprefix)
	    || syserr(_g("failed to rename saved %s to %s"),
	              "$newdirectory.tmp-keep", $expectprefix);
    }

    for my $patch (@patches) {
	printf(_g("%s: applying %s")."\n", $progname, $patch);
	if ($patch =~ /\.$comp_regex$/) {
	    &forkgzipread($patch);
	    *DIFF = *GZIP;
	} else {
	    open DIFF, $patch or error(_g("can't open diff `%s'"), $patch);
	}

	defined(my $c2 = fork) || syserr(_g("fork for patch"));
        if (!$c2) {
            open(STDIN,"<&DIFF") || &syserr(_g("reopen gzip for patch"));
            chdir($newdirectory) || syserr(_g("chdir to %s for patch"), $newdirectory);
	    $ENV{'LC_ALL'}= 'C';
	    $ENV{'LANG'}= 'C';
            exec('patch','-s','-t','-F','0','-N','-p1','-u',
                 '-V','never','-g0','-b','-z','.dpkg-orig') or &syserr(_g("exec patch"));
        }
        close(DIFF);
        $c2 == waitpid($c2,0) || &syserr(_g("wait for patch"));
        $? && subprocerr("patch");

	&reapgzip if $patch =~ /\.$comp_regex$/;
    }

    my $now = time;
    for $fn (keys %filepatched) {
	my $ftr = "$newdirectory/" . substr($fn, length($expectprefix) + 1);
	utime($now, $now, $ftr) ||
	    syserr(_g("cannot change timestamp for %s"), $ftr);
	$ftr.= ".dpkg-orig";
	unlink($ftr) || syserr(_g("remove patch backup file %s"), $ftr);
    }

    if (!(my @s = lstat("$newdirectory/debian/rules"))) {
	$! == ENOENT || syserr(_g("cannot stat %s"), "$newdirectory/debian/rules");
	warning(_g("%s does not exist"), "$newdirectory/debian/rules");
    } elsif (-f _) {
	chmod($s[2] | 0111, "$newdirectory/debian/rules") ||
	    syserr(_g("cannot make %s executable"), "$newdirectory/debian/rules");
    } else {
	warning(_g("%s is not a plain file"), "$newdirectory/debian/rules");
    }

    my $execmode = 0777 & ~umask;
    (my @s = stat('.')) || syserr(_g("cannot stat `.'"));
    my $dirmode = $execmode | ($s[2] & 02000);
    my $plainmode = $execmode & ~0111;
    my $fifomode = ($plainmode & 0222) | (($plainmode & 0222) << 1);

    for $fn (@filesinarchive) {
	$fn=~ s,^$expectprefix,$newdirectory,;
	(my @s = lstat($fn)) ||
	    syserr(_g("cannot stat extracted object `%s'"), $fn);
	my $mode = $s[2];
	my $newmode;

        if (-d _) {
            $newmode= $dirmode;
        } elsif (-f _) {
            $newmode= ($mode & 0111) ? $execmode : $plainmode;
        } elsif (-p _) {
            $newmode= $fifomode;
        } elsif (!-l _) {
            internerr(_g("unknown object `%s' after extract (mode 0%o)"),
                      $fn, $mode);
        } else { next; }
        next if ($mode & 07777) == $newmode;
        chmod($newmode,$fn) ||
            syserr(_g("cannot change mode of `%s' to 0%o from 0%o"),
                   $fn, $newmode, $mode);
    }
    exit(0);
}

sub checkstats {
    my $dscdir = shift;
    my ($f) = @_;
    my @s;
    my $m;
    open(STDIN, "<", "$dscdir/$f") || syserr(_g("cannot read %s"), "$dscdir/$f");
    (@s = stat(STDIN)) || syserr(_g("cannot fstat %s"), "$dscdir/$f");
    $s[7] == $size{$f} || error(_g("file %s has size %s instead of expected %s"),
                                $f, $s[7], $size{$f});
    $m= `md5sum`; $? && subprocerr("md5sum $f"); $m =~ s/\n$//;
    $m = readmd5sum( $m );
    $m eq $md5sum{$f} || error(_g("file %s has md5sum %s instead of expected %s"),
                               $f, $m, $md5sum{$f});
    open(STDIN, "<", "/dev/null") || &syserr(_g("reopen stdin from /dev/null"));
}

sub erasedir {
    my ($dir) = @_;
    if (!lstat($dir)) {
        $! == ENOENT && return;
        syserr(_g("cannot stat directory %s (before removal)"), $dir);
    }
    system 'rm','-rf','--',$dir;
    $? && subprocerr("rm -rf $dir");
    if (!stat($dir)) {
        $! == ENOENT && return;
        syserr(_g("unable to check for removal of dir `%s'"), $dir);
    }
    failure(_g("rm -rf failed to remove `%s'"), $dir);
}

# check diff for sanity, find directories to create as a side effect
sub checkdiff
{
    my $diff = shift;
    if ($diff =~ /\.$comp_regex$/) {
	&forkgzipread($diff);
	*DIFF = *GZIP;
    } else {
	open DIFF, $diff or error(_g("can't open diff `%s'"), $diff);
    }
    $/="\n";
    $_ = <DIFF>;

  HUNK:
    while (defined($_) || !eof(DIFF)) {
	# skip cruft leading up to patch (if any)
	until (/^--- /) {
	    last HUNK unless defined ($_ = <DIFF>);
	}
	# read file header (---/+++ pair)
	s/\n$// or error(_g("diff `%s' is missing trailing newline"), $diff);
	s/^--- // or
	    error(_g("expected ^--- in line %d of diff `%s'"), $., $diff);
	s/\t.*//;
	$_ eq '/dev/null' or s!^(\./)?[^/]+/!$expectprefix/! or
	    error(_g("diff `%s' patches file with no subdirectory"), $diff);
	/\.dpkg-orig$/ and
	    error(_g("diff `%s' patches file with name ending .dpkg-orig"),
	          $diff);
	$fn = $_;

	(defined($_= <DIFF>) and s/\n$//) or
	    error(_g("diff `%s' finishes in middle of ---/+++ (line %d)"),
	          $diff, $.);

	s/\t.*//;
	(s/^\+\+\+ // and s!^(\./)?[^/]+/!!) or
	    error(_g("line after --- isn't as expected in diff `%s' (line %d)"),
	          $diff, $.);

	if ($fn eq '/dev/null') {
	    $fn = "$expectprefix/$_";
	} else {
	    $_ eq substr($fn, length($expectprefix) + 1) or
	        error(_g("line after --- isn't as expected in diff `%s' (line %d)"),
	              $diff, $.);
	}

	my $dirname = $fn;
	if ($dirname =~ s,/[^/]+$,, && !defined($dirincluded{$dirname})) {
	    $dirtocreate{$dirname} = 1;
	}
	defined($notfileobject{$fn}) &&
	    error(_g("diff `%s' patches something which is not a plain file"),
	          $diff);

	defined($filepatched{$fn}) &&
	    $filepatched{$fn} eq $diff &&
	    error(_g("diff patches file %s twice"), $fn);
	$filepatched{$fn} = $diff;

	# read hunks
	my $hunk = 0;
	while (defined($_ = <DIFF>) && !(/^--- / or /^Index:/)) {
	    # read hunk header (@@)
	    s/\n$// or error(_g("diff `%s' is missing trailing newline"), $diff);
	    next if /^\\ No newline/;
	    /^@@ -\d+(,(\d+))? \+\d+(,(\d+))? @\@( .*)?$/ or
		error(_g("Expected ^\@\@ in line %d of diff `%s'"), $., $diff);
	    my ($olines, $nlines) = ($1 ? $2 : 1, $3 ? $4 : 1);
	    ++$hunk;
	    # read hunk
	    while ($olines || $nlines) {
		defined($_ = <DIFF>) or
		    error(_g("unexpected end of diff `%s'"), $diff);
		s/\n$// or
		    error(_g("diff `%s' is missing trailing newline"), $diff);
		next if /^\\ No newline/;
		if (/^ /) { --$olines; --$nlines; }
		elsif (/^-/) { --$olines; }
		elsif (/^\+/) { --$nlines; }
		else {
		    error(_g("expected [ +-] at start of line %d of diff `%s'"),
		          $., $diff);
		}
	    }
	}
	$hunk or error(_g("expected ^\@\@ at line %d of diff `%s'"), $., $diff);
    }
    close(DIFF);
    
    &reapgzip if $diff =~ /\.$comp_regex$/;
}

sub checktype {
    my ($dir, $fn, $type) = @_;

    if (!lstat("$dir/$fn")) {
        &unrepdiff2(_g("nonexistent"),$type{$fn});
    } else {
	my $v = eval("$type _ ? 2 : 1");
	$v || internerr(_g("checktype %s (%s)"), "$@", $type);
        return 1 if $v == 2;
        &unrepdiff2(_g("something else"),$type{$fn});
    }
    return 0;
}

sub setopmode {
    defined($opmode) && &usageerr(_g("only one of -x or -b allowed, and only once"));
    $opmode= $_[0];
}

sub unrepdiff {
    printf(STDERR _g("%s: cannot represent change to %s: %s")."\n",
                  $progname, $fn, $_[0])
        || &syserr(_g("write syserr unrep"));
    $ur++;
}

sub unrepdiff2 {
    printf(STDERR _g("%s: cannot represent change to %s:\n".
                     "%s:  new version is %s\n".
                     "%s:  old version is %s\n"),
                  $progname, $fn, $progname, $_[1], $progname, $_[0])
        || &syserr(_g("write syserr unrep"));
    $ur++;
}

sub forkgzipwrite {
    $compressor->set_compressed_filename($_[0]);
    $compressor->set_compression_level($comp_level);

    my $handle;
    $compressor->compress(from_pipe => \$handle);
    open(GZIP, ">>&=", $handle) || syserr(_g("cannot associate handle"));
    close($handle);
}

sub forkgzipread {
    $compressor->set_compressed_filename($_[0]);
    $compressor->set_compression_level($comp_level);

    my $handle;
    $compressor->uncompress(to_pipe => \$handle);
    open(GZIP, "<&=", $handle) || syserr(_g("cannot associate handle"));
    close($handle);
}

sub reapgzip {
    $compressor->wait_end_process();
}

my %added_files;
sub addfile {
    my ($fields, $filename)= @_;
    $added_files{$filename}++ &&
        internerr(_g("tried to add file `%s' twice"), $filename);
    stat($filename) || syserr(_g("could not stat output file `%s'"), $filename);
    my $size = (stat _)[7];
    my $md5sum= `md5sum <$filename`;
    $? && &subprocerr("md5sum $filename");
    $md5sum = readmd5sum( $md5sum );
    $fields->{'Files'}.= "\n $md5sum $size $filename";
}

sub readmd5sum {
    (my $md5sum = shift) or return;
    $md5sum =~ s/^([0-9a-f]{32})\s*\*?-?\s*\n?$/$1/o
        || failure(_g("md5sum gave bogus output `%s'"), $md5sum);
    return $md5sum;
}

