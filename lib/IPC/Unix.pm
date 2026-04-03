=head1 NAME

IPC::Unix - POSIX bidi popen, re-written

=head1 SYNOPSIS

   my $child = IPC::Unix->new(
      "git", "mktree"
   );
   $child->set(qw( hash-object -t tree ));
   $child->prog("git");
   $child->file("/usr/bin/git");
   $child->chdir( @dirs );

   $child->new->set(qw( version ));

   open my $null, '+>', '/dev/null';
   $child->dup( "<&-", "2>&1" );  # close or dup2
   $child->dup( ">", my $pipe );     # pipe+dup2
   $child->dup( \*STDERR, ">&", $null );  # dup2

   $child->env( %ENV );
   $child->setenv( TERM => 'dumb' );
   $child->unsetenv( qw(VISUAL EDITOR) );
   $child->resetenv( 'TERM' );

   $pid = $child->spawn;
   $child->close();
   waitpid($pid, 0);
   $child->ok();

=cut

package IPC::Unix;

our $VERSION = '0.0_001';
$VERSION = eval $VERSION;

use 5.006;
use strict;
use warnings;

use Config;
use Fcntl qw( F_GETFD F_SETFD FD_CLOEXEC );
use IO::Handle;   # for IO methods (pre-v5.14)

use Carp qw(croak);
use Scalar::Util qw(refaddr);
use Symbol ();

use Data::Dumper;
use File::Basename;
use File::Spec;

sub quote
{
	my @fmt = map { /^"/ or $_ = "\"$_\""; $_ }
		Data::Dumper->new(\@_)->Useqq(1)
		->Indent(0)->Terse(1)->Dump();
	wantarray ? @fmt : $fmt[0];
}

our $TRACE;
sub DEBUG
{
	my $fh = ref($_[0]) ? shift : \*STDERR;
	local $" = '';
	my (undef, $file, $line) = caller;
	my $name = File::Spec->abs2rel($file, ".");
	$name = $file if $name =~ m!^../!;
	my $fmt = sprintf "%s:%03d [pid=%d] %s", $name, $line, $$, "@_";
	chomp $fmt;  print $fh "$fmt\n";
}

sub POINT
{
	if (defined pos($_[0])) {
		return quote(substr($_[0], 0, pos($_[0])))
		. "|" . quote(substr($_[0], pos($_[0])));
	}
	&quote;
}

sub FILENO
{
	my $fh = shift;
	# fileno returns "undef" for an unopened handle
	# ... which shouldn't happen, but eh.
	my $fileno = fileno($fh);
	defined $fileno or $fileno = '-';
	my $globs = do {  # describe the blob
		# (probably shouldn't compare the filenos...)
		my $addr = refaddr($fh);
		if   ($addr == refaddr(\*STDIN)) { "STDIN"; }
		elsif ($addr == refaddr(\*STDOUT)) { "STDOUT"; }
		elsif ($addr == refaddr(\*STDERR)) { "STDERR"; }
		else { "$fh" }  # GLOB(0x...)
	};
	"$fileno($globs)";
}

sub new {
	my $class = shift;
	my $self = do {
		if (ref $class) {
			bless {
				bin => $class->{bin},
				cmd => [ @{$class->{cmd}} ],
				env => [ @{$class->{env}} ],
			}, ref $class;
		} else {
			@_ or Carp::croak("${class}: new: no argument");
			bless { }, $class;
		}
	};

	if (@_) {
		$self->{bin} = $_[0];
		$self->{cmd} = [ basename($_[0]), @_[1 .. $#_] ];
	}
	$self;
}

# argv ("v" part of execvpe)
sub set {
	my $self = shift;
	my $argv = $self->{cmd};
	splice @$argv, 1, @$argv - 1, @_;
	$self;
}
sub prog {
	my $self = shift;
	my $argv = $self->{cmd};
	return $argv->[0] if !@_;
	$argv->[0] = $_[0]; $self;
}
sub file {
	my $self = shift;
	return $self->{bin} if !@_;
	$self->{bin} = $_[0]; $self;
}

sub chdir {
	my $self = shift;
	push @{$self->{dir}}, @_;
	$self;
}

# envp ("e" part of execvpe)
sub env {
	my $self = shift;
	return $self->{env} if !@_;
	$self->{env} = { @_ };
}
sub setenv {
	my $self = shift;
	my %setenv = @_;
	defined $self->{setenv} or $self->{setenv} = {};
	while (my ($K, $V) = each %setenv) {
		$self->{setenv}->{$K} = $V;
	}
	$self;
}
sub resetenv {
	my $self = shift;
	foreach my $K (@_) {
		delete $self->{setenv}->{$K};
	}
	$self;
}
sub unsetenv {
	my $self = shift;
	$self->setenv(map { $_ => undef } @_);
}

sub dup {
	my $self = $_[0];
	my $class = ref $self;
	$class = defined $class ? "$class: " : "";
	my $pkg = caller;
	DEBUG ("dup(@{[@_-1]}+1 elt): called from $pkg") if $TRACE;
	for (my $o = 1; $o < @_; ++$o) {
		DEBUG ("BEGIN\n") if $TRACE;
		my ($adv, $fh0, $fh1, $mode);

		if (ref $_[$o] eq 'GLOB') {
			DEBUG ("  toke [$o]=$_[$o] src ", FILENO($_[$o])) if $TRACE;
			$fh0 = $_[$o++];
			$o < @_ or croak "${class}dup: index $o: unexpected end after GLOB reference";
		} elsif (ref \$_[$o] eq 'GLOB') {
			DEBUG ("  toke [$o]=\${", \$_[$o], "} src ", FILENO(\$_[$o])) if $TRACE;
			$fh0 = \$_[$o++];
			$o < @_ or croak "${class}dup: index $o: unexpected end after GLOB scalar";
		} else {
			pos($_[$o]) = 0;
			if ($_[$o] =~ /\G([0-9]+)/gc) {
				$1 > 2 and croak "${class}dup: index $o: don't know how to map file descriptor: $1";
				$fh0 = \(*STDIN, *STDOUT, *STDERR)[$1];
			} elsif ($_[$o] =~ /\G([^<>]+)/gc) {
				$fh0 = Symbol::qualify_to_ref($1, $pkg);
				++$o;
				$o < @_ or croak "${class}dup: index $o: unexpected end after file descriptor";
			} elsif ($_[$o] =~ /^>/)
				{ $fh0 = \*STDOUT; }
			elsif ($_[$o] =~ /^</)
				{ $fh0 = \*STDIN; }
			else {
				croak "${class}dup: index $o: expecting source file";
			}
			DEBUG ("  toke [$o]=", POINT($_[$o]), " src ", FILENO($fh0)) if $TRACE;
			if ($_[$o] =~ /\G\z/gc) {
				++$o;
				$o < @_ or croak "${class}dup: index $o: unexpected end after file descriptor";
			}
		}

		unless ($_[$o] =~ /([<>]&-?|\+?[<>])/gc) {
			croak "${class}dup: index $o: cannot find a valid file mode in: $_[$o]";
		} else {
			$mode = $1;
			DEBUG ("  toke [$o]=@{[POINT($_[$o])]} mode=@{[quote($mode)]}") if $TRACE;
			if ($mode eq '<&-' || $mode eq '>&-') {
				push @{$self->{dup}}, [ $fh0, $mode ];
				DEBUG ("    CLOSE ", FILENO($fh0), " $mode-") if $TRACE;
				next;
			} elsif ($_[$o] =~ /\G\z/gc) {
				++$o;
				$o < @_ or croak "${class}dup: index $o: unexpected end after file mode";
				$adv = 1;
			}
		} # else "$adv = 0" here.

		# Handle < or >
		if ($mode =~ /\A\+?[<>]\z/) {
			if (defined $_[$o]) {
				DEBUG ("  toke [$o]=@{[$adv ? quote($_[$o]) : POINT($_[$o])]}") if $TRACE;
				my $filename = $adv ? $_[$o] : substr($_[$o], pos($_[$o]));
				push @{$self->{dup}}, [ $fh0, $mode, $filename ];
				DEBUG ("    OPEN $$fh0 $mode @{[quote($filename)]}") if $TRACE;
			} else {
				$mode =~ y/+//d;
				if ($mode eq '<') {
					pipe $fh1, $_[$o] or croak "${class}dup: index $o: pipe `<': $!";
					DEBUG ("  PIPE <(", FILENO($fh1), ") >([$o]=", FILENO($_[$o]), ")") if $TRACE;
					$fh1->autoflush(1);
				} else {
					pipe $_[$o], $fh1 or croak "${class}dup: index $o: pipe `>': $!";
					DEBUG ("  PIPE <([$o]=", FILENO($_[$o]), ") >(", FILENO($fh1), ")") if $TRACE;
					$_[$o]->autoflush(1);
				}
				push @{$self->{dup}}, [ $fh0, "$mode&", $fh1 ];
				DEBUG ("    DUP2 ", FILENO($fh0), " $mode& ", FILENO($fh1)) if $TRACE;
				push @{$self->{fhs}}, [ $fh1, $_[$o] ];
			}
			next;
		}

		if (ref $_[$o] eq 'GLOB') {
			$fh1 = $_[$o];
			DEBUG ("  toke [$o]=$_[$o] dst ", FILENO($fh1)) if $TRACE;
		} elsif (ref \$_[$o] eq 'GLOB') {
			$fh1 = \$_[$o];
			DEBUG ("  toke [$o]=\${", \$_[$o], "} dst ", FILENO($fh1)) if $TRACE;
		} elsif (defined $_[$o]) {
			if ($_[$o] =~ /\G([0-9]+)/gc) {
				$1 > 2 and croak "${class}dup: index $o: don't know how to map file descriptor: $1";
				$fh1 = \(*STDIN, *STDOUT, *STDERR)[$1];
			} elsif ($_[$o] =~ /\G(.+)/gc) {
				Symbol::qualify_to_ref($1, $_);
			} else {
				croak "${class}dup: index $o: unexpected end while expecting destination file";
			}
			DEBUG ("  toke [$o]=", POINT($_[$o]), " dst ", FILENO($fh1)) if $TRACE;
		}

		if (defined $fh1) {
			push @{$self->{dup}}, [ $fh0, $mode, $fh1 ];
			DEBUG ("    DUP2 ", FILENO($fh0), " $mode ", FILENO($fh1)) if $TRACE;
			next;
		} else {
			# Weird way to write ">&-" or "<&-" :/
			push @{$self->{dup}}, [ $fh0, "$mode-" ];
			DEBUG ("    CLOSE ", FILENO($fh0), " $mode-") if $TRACE;
		}
	}
	$self;
}

sub spawn {
	my $self = shift;
	my $class = ref $self;
	$class = defined $class ? "$class: " : "";

	# error communication
	pipe my ($stat_r, $stat_w);
	pipe my ($trac_r, $trac_w) if $TRACE;

	$stat_w->autoflush(1);
	$trac_w->autoflush(1) if $TRACE;

	my @dir = $self->{dir} ? @{$self->{dir}} : ();
	my @dup = $self->{dup} ? @{$self->{dup}} : ();
	my @fhs = $self->{fhs} ? @{$self->{fhs}} : ();

	defined (my $kid = fork) or croak "${class}spawn: fork: $!";
	if ($kid) {  # parent process
		DEBUG ("FORK => $kid") if $TRACE;

		close $stat_w;
		close $trac_w;
		close $_->[0] foreach @fhs;

		if ($TRACE) { while (<$trac_r>) { print STDERR $_; } }

		my $mesg = do { local $/; <$stat_r> };
		if (defined $mesg && do { chomp $mesg; length $mesg }) {
			croak "${class}spawn: $mesg";
		}
		close $stat_r;
		$self->{pid} = $kid;
		return $kid;
	}

	# child process (will NEVER return)
	DEBUG $trac_w, ("(hi Mom!)") if $TRACE;
	close $stat_r;
	close $trac_r;
	close $_->[1] foreach @fhs;

	eval {
		# Make $stat_w close on exec.  (It probably
		# already has that flag, given that Perl sets
		# FD_CLOEXEC automatically for fds above $^F.
		# ... but it's good to be safe.)
		my $flags = fcntl( $stat_w, F_GETFD, 0 )
			or die "fcntl GETFD failed on status fd: $!\n";
		fcntl( $stat_w, F_SETFD, $flags | FD_CLOEXEC )
			or die "fcntl SETFD failed on status fd: $!\n";

		if ($TRACE) {
			my $flags = fcntl( $trac_w, F_GETFD, 0 )
				or die "fcntl GETFD failed on trace fd: $!\n";
			fcntl( $trac_w, F_SETFD, $flags | FD_CLOEXEC )
				or die "fcntl SETFD failed on trace fd: $!\n";
		}

		DEBUG $trac_w, ("  * working directory") if $TRACE;
		foreach (@dir) {
			DEBUG $trac_w, ("    CHDIR @{[quote($_)]}") if $TRACE;
			unless (CORE::chdir $_) {
				my $dirs = quote($_);
				die "chdir $dirs: $!\n";
			}
		}

		DEBUG $trac_w, ("  * I/O redirection") if $TRACE;
		foreach my $op (@dup) {
			# mode >&- or <&-: close
			if (@$op == 2) {
				if ($TRACE) {
					my $fd0 = FILENO($op->[0]);
					DEBUG $trac_w, ("    CLOSE $fd0");
				}
				close $op->[0];
			} else {
				my ($fh0, $mode, $fh1) = @$op;
				if ($TRACE) {
					my $fd0 = FILENO($fh0);
					my $fd1 = FILENO($fh1);
					DEBUG $trac_w, ("    DUP2 $fd0 $mode $fd1");
				}
				unless (open $fh0, $mode, $fh1) {
					my $fd0 = FILENO($fh0);
					my $fd1 = FILENO($fh1);
					die "open $fd0 $mode $fd1: $!\n";
				}
			}
		}

		DEBUG $trac_w, ("  * environment") if $TRACE;
		%ENV = %{$self->{env}} if $self->{env};
		DEBUG $trac_w, ("    ENV ", $self->{env} ? join " ", (
			map { sprintf "%s=%s", quote($_, $ENV{$_}) }
			keys %ENV
		) : "inherited") if $TRACE;
		if ($self->{setenv}) {
			while (my ($K, $V) = %{$self->{setenv}}) {
				if (defined $V) {
					$ENV{$K} = $V;
					DEBUG $trac_w, (
						"    SETENV ", sprintf
						("%s=%s", quote($K,$V))
					) if $TRACE;
				} else {
					delete $ENV{$K};
					DEBUG $trac_w, (
						"    UNSETENV ",
						quote($K)
					) if $TRACE;
				}
			}
		}
		if ($TRACE) {
			local $" = ", ";
			my $bins = quote($self->{bin});
			my $args = join ", ", quote(@{$self->{cmd}});
			DEBUG $trac_w, ("  EXEC { $bins } [ $args ]");
		}
		exec { $self->{bin} } @{$self->{cmd}} or do {
			my $bins = quote($self->{bin});
			die "exec $bins: $!\n";
		}
	};

	# Something went wrong
	close $trac_w;
	print $stat_w $@;
	close $stat_w;

	# DIE
	eval { require POSIX; POSIX::_exit(255) };
	exit 255;
}
sub pid { $_[0]->{pid}; }

sub opened { !!$_[0]->{fhs} }
sub close {
	my $self = shift;
	my $class = ref $self;
	$class = defined $class ? "$class: " : "";
	return 1 if !$self->opened;
	my $aok = 1;
	my @fhs = @{$self->{fhs}};
	foreach (reverse 0 .. $#fhs) {
		if ($fhs[$_]->[0]->opened) {
			unless (close $fhs[$_]->[0]) {
				my $fd = fileno($fhs[$_]->[0]);
				defined $fd or $fd = "$fhs[$_]->[0]";
				Carp::carp "${class}close($fd): $!";
				$aok = 0;
			} else {
				splice @fhs, $_, 1, ();
			}
		}
	}
	unless (@fhs) {
		delete $self->{fhs};
	} else {
		@{$self->{fhs}} = @fhs;
	}
	return $aok;
}

sub exited { defined $_[0]->{err} }
sub wait {
	my $self = shift;
	return $self->{err} if $self->exited;
	my $class = ref $self;
	$class = defined $class ? "$class: " : "";
	my $pid = $self->{pid};
	my $kid = waitpid $pid, 0;
	if ($kid == -1) {
		Carp::carp("${class}waitpid($pid): $!");
		return -1;
	} else {
		return $self->seterror($?);
	}
}
sub seterror {
	my $self = shift;
	my $stat = @_ ? shift : $?;
	$self->{err} = $stat;
	return $self->{err};
}
sub ok {
	my $self = shift;
	my $class = ref $self;
	$class = defined $class ? "$class: " : "";

	defined (my $stat = $self->{err}) or
		croak "${class}ok: called too early";
	return if $self->{err} == 0;

	my $status = $self->{err} >> 8;
	my $signal = $self->{err} & 127;
	my $coredump = $self->{err} & 128;

	my $sig_name;
	if ($signal) {
		my @sig_name = split / /, $Config{'sig_name'};
		my $sig_name = $sig_name[$signal];
	}

	croak "{" . quote($self->{bin}) . "} "
		# XXX: May be very long???
		. quote($self->{cmd})
		. " [pid=$self->{pid}] died of code $status"
		. ( $signal == 0 ? "" : $sig_name ?
			", SIG$sig_name" : ", signal $signal" )
		. ( "(core dumped)" x!! $coredump );
}

1; # make require happy
