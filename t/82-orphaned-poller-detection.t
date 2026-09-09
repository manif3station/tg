use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Lock;

# TGT-113 (live-experienced incident: a poller crashed mid-version-bump
# race, never auto-restarted, and a SEPARATE orphaned instance under a
# different PID with a stale command line - missing '-d tira' - was
# found still running the entire time, competing for the same bot
# token's getUpdates queue). D2TG::Lock::find_other_pollers scans a
# /proc-shaped directory for other processes whose cmdline matches a
# poller pattern, excluding the caller's own PID - independent of
# TGT-084's own lock-eviction path, which only ever sees whichever PID
# the lock FILE currently names, not every process actually polling.

sub _fake_proc {
    my (%pids) = @_;
    my $proc_dir = tempdir( CLEANUP => 1 );
    for my $pid ( keys %pids ) {
        my $pid_dir = File::Spec->catdir( $proc_dir, $pid );
        mkdir $pid_dir;
        open my $fh, '>', File::Spec->catfile( $pid_dir, 'cmdline' ) or die $!;
        print {$fh} $pids{$pid};
        close $fh;
    }
    return $proc_dir;
}

{
    my $proc_dir = _fake_proc(
        1001 => "perl\0/opt/tg/cli/poller.pl\0",
        1002 => "perl\0/opt/other-skill/cli/whatever.pl\0",
    );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( [ sort @found ], [1001], 'finds the other poller.pl process, ignores an unrelated one' );
}

{
    my $proc_dir = _fake_proc(
        1001 => "perl\0/opt/tg/cli/poller.pl\0",
        1003 => "perl\0/opt/tg/cli/poller.pl\0",
    );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( [ sort { $a <=> $b } @found ], [ 1001, 1003 ], 'finds multiple other poller processes' );
}

{
    # Own PID excluded even if it happens to have a matching cmdline
    # (a real /proc always includes the caller's own entry).
    my $proc_dir = _fake_proc(
        $$    => "perl\0/opt/tg/cli/poller.pl\0",
        1004 => "perl\0/opt/tg/cli/poller.pl\0",
    );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( [ sort @found ], [1004], 'excludes the caller\'s own PID even when it matches the pattern' );
}

{
    my $proc_dir = _fake_proc( 1005 => "perl\0/opt/other-skill/cli/whatever.pl\0" );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'no match when no other process looks like a poller' );
}

{
    my $proc_dir = tempdir( CLEANUP => 1 );    # empty - no /proc entries at all

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'returns empty, not dying, against an empty proc directory' );
}

{
    # A non-numeric entry (e.g. 'self', 'net', 'thread-self' in a real
    # /proc) must be skipped, not treated as a PID.
    my $proc_dir = tempdir( CLEANUP => 1 );
    mkdir File::Spec->catdir( $proc_dir, 'self' );
    open my $fh, '>', File::Spec->catfile( $proc_dir, 'self', 'cmdline' ) or die $!;
    print {$fh} "perl\0/opt/tg/cli/poller.pl\0";
    close $fh;

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'non-numeric proc entries (self, net, ...) are skipped' );
}

{
    # A pid directory that has already exited between readdir and open
    # (cmdline unreadable) must not die the whole scan.
    my $proc_dir = tempdir( CLEANUP => 1 );
    mkdir File::Spec->catdir( $proc_dir, '9999' );    # no cmdline file inside

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'a pid directory with an unreadable/missing cmdline is skipped, not fatal' );
}

{
    # An entirely unreadable/nonexistent proc_dir (e.g. a non-Linux host,
    # or a permission-restricted /proc) must return empty, not die.
    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => '/does/not/exist' );
    is_deeply( \@found, [], 'an unreadable proc_dir returns empty rather than dying' );
}

# Codex review finding: the default pattern must not false-positive on
# a substring match, a match spanning two unrelated argv elements, or a
# name that merely CONTAINS "poller.pl" without actually being it.
{
    my $proc_dir = _fake_proc(
        2001 => "perl\0/opt/tg/cli/not-a-poller.pl\0",
        2002 => "perl\0/opt/tg/cli/poller.pl.bak\0",
        2003 => "perl\0--note=poller.pl\0",
    );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'does not false-positive on not-a-poller.pl, poller.pl.bak, or --note=poller.pl' );
}

{
    # NUL-separated argv must be matched element-by-element, not joined
    # with spaces first - joining could let an anchored end-of-string
    # pattern match across a boundary that was never really contiguous.
    my $proc_dir = _fake_proc( 2004 => "perl\0/opt/tg/cli/poller\0.pl-not-real-either\0" );

    my @found = D2TG::Lock::find_other_pollers( own_pid => $$, proc_dir => $proc_dir );
    is_deeply( \@found, [], 'does not match a pattern spanning two separate argv elements' );
}

{
    # A custom pattern/proc_dir pair both actually get used, not just
    # the defaults.
    my $proc_dir = _fake_proc(
        3001 => "perl\0/opt/tg/cli/poller.pl\0",
        3002 => "perl\0/opt/other-project/cli/custom-worker.pl\0",
    );

    my @found = D2TG::Lock::find_other_pollers(
        own_pid  => $$,
        proc_dir => $proc_dir,
        pattern  => qr{custom-worker\.pl$},
    );
    is_deeply( \@found, [3002], 'a caller-supplied pattern overrides the default poller.pl match' );
}

# CLI-level: cli/poller.pl actually warns when a real second process
# whose cmdline matches the poller pattern is genuinely running,
# independent of D2TG::Lock's own eviction path (which only ever knows
# about whichever single PID the lock FILE currently names).
{
    my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

    # A real second process whose argv literally contains a path ending
    # in poller.pl, so it shows up in its own /proc/<pid>/cmdline exactly
    # like a genuine orphaned instance would - this project's tests
    # already assume Linux (t/54, t/66, t/67's own fork-based process
    # tests), and this container is Linux, so a real /proc read is a
    # more faithful proof than a fully mocked one for this one case.
    my $fake_poller_dir = tempdir( CLEANUP => 1 );
    my $fake_poller     = File::Spec->catfile( $fake_poller_dir, 'poller.pl' );
    open my $fh, '>', $fake_poller or die $!;
    print {$fh} "#!/usr/bin/env perl\nsleep 30;\n";
    close $fh;
    chmod 0755, $fake_poller;

    # TGT-141: the fake child must inherit the SAME D2TG_TOKEN the real
    # poller.pl below will run with, so this genuinely tests the
    # same-token "real conflict, worth investigating" case - set before
    # forking, since fork+exec inherits %ENV from this point onward.
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN} = 'test-token';

    my $child_pid = fork();
    die "fork failed: $!" unless defined $child_pid;
    if ( $child_pid == 0 ) {
        exec( $^X, $fake_poller );
        exit 1;
    }

    # Give the child a moment to actually exec() into the fake poller
    # script. Checking mere existence of /proc/$child_pid/cmdline is not
    # enough - it exists the instant fork() returns, before exec()
    # replaces argv, so a reader could see the pre-exec cmdline (this
    # test process's own copied argv) and race ahead believing the
    # child is ready when it isn't yet. Read the actual content and
    # require it to already name the fake poller script.
    my $tries = 0;
    my $child_cmdline = '';
    while ( $tries++ < 200 ) {
        if ( open my $cfh, '<', "/proc/$child_pid/cmdline" ) {
            local $/;
            $child_cmdline = <$cfh> // '';
            close $cfh;
        }
        last if $child_cmdline =~ /\Q$fake_poller\E/;
        select( undef, undef, undef, 0.01 );
    }

    # Codex review finding: the loop above must be an explicit gate, not
    # a delay that silently proceeds either way - an exec() failure or
    # an unusually slow child would otherwise still let the test run and
    # reproduce the exact false-negative flake this fix exists to close.
    unless ( $child_cmdline =~ /\Q$fake_poller\E/ ) {
        kill 'KILL', $child_pid;
        waitpid( $child_pid, 0 );
        ( my $shown_cmdline = $child_cmdline ) =~ s/\0/ /g;
        BAIL_OUT("fake poller child (PID $child_pid) never exec()'d into $fake_poller - last seen cmdline: '$shown_cmdline'");
    }

    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $poller_pid = IPC::Open3::open3( my $in, $child_out, $child_err, $poller_cli );

    my $first_line = <$child_out>;    # startup line - blocks until it's printed
    my $warning_line = <$child_err>;

    like(
        $warning_line,
        qr/WARNING.*possible orphaned poller instance.*\Q$child_pid\E/,
        'cli/poller.pl warns on STDERR naming the real other poller-shaped process\'s PID'
    );

    kill 'KILL', $poller_pid;
    waitpid( $poller_pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );

    kill 'KILL', $child_pid;
    waitpid( $child_pid, 0 );
}

{
    # Regression: a healthy single instance (no other poller-shaped
    # process running) must NOT print the warning - a false positive
    # here would be its own incident.
    my $poller_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $poller_pid = IPC::Open3::open3( my $in, $child_out, $child_err, $poller_cli );

    my $first_line = <$child_out>;

    kill 'KILL', $poller_pid;
    waitpid( $poller_pid, 0 );

    local $/;
    my $err = <$child_err> // '';
    close $_ for grep { defined } ( $in, $child_out, $child_err );

    unlike( $err, qr/WARNING.*orphaned/, 'no false-positive orphaned-instance warning for a healthy single instance' );
}

{
    # TGT-141 core scenario, live-reproduced: a sibling project's own
    # legitimate poller (different D2TG_TOKEN, no real getUpdates
    # collision) must get the reassuring NOTE wording, never the
    # urgent WARNING framing.
    my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

    my $fake_poller_dir = tempdir( CLEANUP => 1 );
    my $fake_poller     = File::Spec->catfile( $fake_poller_dir, 'poller.pl' );
    open my $fh, '>', $fake_poller or die $!;
    print {$fh} "#!/usr/bin/env perl\nsleep 30;\n";
    close $fh;
    chmod 0755, $fake_poller;

    # The sibling's own token, deliberately different from the one the
    # real poller.pl below will run with.
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN} = 'sibling-project-different-token';

    my $child_pid = fork();
    die "fork failed: $!" unless defined $child_pid;
    if ( $child_pid == 0 ) {
        exec( $^X, $fake_poller );
        exit 1;
    }

    my $tries = 0;
    my $child_cmdline = '';
    while ( $tries++ < 200 ) {
        if ( open my $cfh, '<', "/proc/$child_pid/cmdline" ) {
            local $/;
            $child_cmdline = <$cfh> // '';
            close $cfh;
        }
        last if $child_cmdline =~ /\Q$fake_poller\E/;
        select( undef, undef, undef, 0.01 );
    }
    unless ( $child_cmdline =~ /\Q$fake_poller\E/ ) {
        kill 'KILL', $child_pid;
        waitpid( $child_pid, 0 );
        BAIL_OUT("fake sibling poller child (PID $child_pid) never exec()'d into $fake_poller");
    }

    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    $ENV{D2TG_TOKEN}   = 'our-own-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $poller_pid = IPC::Open3::open3( my $in, $child_out, $child_err, $poller_cli );

    my $first_line   = <$child_out>;
    my $warning_line = <$child_err>;

    unlike( $warning_line, qr/^WARNING/,
        'a sibling project\'s own poller (different token) never gets the urgent WARNING framing' );
    like( $warning_line, qr/^NOTE.*\Q$child_pid\E.*sibling project/,
        'it gets the reassuring NOTE wording instead, naming the sibling-project explanation' );

    kill 'KILL', $poller_pid;
    waitpid( $poller_pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );

    kill 'KILL', $child_pid;
    waitpid( $child_pid, 0 );
}

done_testing();
