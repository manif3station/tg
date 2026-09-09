use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Lock;

# TGT-141 (live-reproduced external finding, zen-framework crosscheck
# report, 2026-09-09): find_other_pollers' warning fires whenever any
# process on the host has a poller-shaped cmdline, even a completely
# unrelated sibling project's own legitimate poller (different bot
# token, no real getUpdates collision). The warning text already
# hedges with "If genuinely another live poller sharing this bot
# token" without ever actually checking the token. This cross-checks
# the flagged PID's own D2TG_TOKEN (via /proc/<pid>/environ) against
# the running instance's own, so the warning can distinguish a real
# same-token conflict from a benign sibling-project false positive.

sub _fake_proc_with_environ {
    my (%pids) = @_;
    my $proc_dir = tempdir( CLEANUP => 1 );
    for my $pid ( keys %pids ) {
        my $pid_dir = File::Spec->catdir( $proc_dir, $pid );
        mkdir $pid_dir;
        open my $fh, '>', File::Spec->catfile( $pid_dir, 'environ' ) or die $!;
        print {$fh} $pids{$pid};
        close $fh;
    }
    return $proc_dir;
}

{
    my $proc_dir = _fake_proc_with_environ(
        1001 => "PATH=/usr/bin\0D2TG_TOKEN=572239131:sameToken\0D2TG_CHAT_ID=1\0",
    );

    is( D2TG::Lock::classify_other_poller_token( 1001, own_token => '572239131:sameToken', proc_dir => $proc_dir ),
        'same', 'a flagged PID whose own D2TG_TOKEN matches ours is classified same' );
}

{
    my $proc_dir = _fake_proc_with_environ(
        1002 => "PATH=/usr/bin\0D2TG_TOKEN=8252713626:differentToken\0D2TG_CHAT_ID=1\0",
    );

    is( D2TG::Lock::classify_other_poller_token( 1002, own_token => '572239131:sameToken', proc_dir => $proc_dir ),
        'different', 'a flagged PID whose own D2TG_TOKEN differs from ours is classified different' );
}

{
    # No environ file at all (permission-restricted, different user,
    # or the process already exited) - can't tell, must not guess.
    my $proc_dir = tempdir( CLEANUP => 1 );
    mkdir File::Spec->catdir( $proc_dir, '1003' );

    is( D2TG::Lock::classify_other_poller_token( 1003, own_token => '572239131:sameToken', proc_dir => $proc_dir ),
        'unknown', 'an unreadable environ is classified unknown, never guessed as same or different' );
}

{
    # environ readable but no D2TG_TOKEN key in it at all (e.g. an
    # unrelated process that merely matched the poller.pl cmdline
    # pattern coincidentally).
    my $proc_dir = _fake_proc_with_environ( 1004 => "PATH=/usr/bin\0HOME=/home/x\0" );

    is( D2TG::Lock::classify_other_poller_token( 1004, own_token => '572239131:sameToken', proc_dir => $proc_dir ),
        'unknown', 'a process with no D2TG_TOKEN in its environ is classified unknown' );
}

{
    # Our own token unknown/undef - can't compare either way.
    my $proc_dir = _fake_proc_with_environ(
        1005 => "D2TG_TOKEN=572239131:sameToken\0",
    );

    is( D2TG::Lock::classify_other_poller_token( 1005, own_token => undef, proc_dir => $proc_dir ),
        'unknown', 'an undef own_token is classified unknown, never compared' );
}

{
    # A Codex review finding: 'unknown' (unreadable environ) is NOT the
    # same claim as 'different' (confirmed a different token) - an
    # unknown PID could still genuinely be a same-token conflict this
    # instance simply couldn't verify, so cli/poller.pl must give it
    # its own, more cautious wording rather than sharing the confident
    # "almost certainly...no action needed" text the different-token
    # branch uses. Structural check (matching t/104's own precedent for
    # a CLI print-statement content requirement).
    open my $fh, '<', "$Bin/../cli/poller.pl" or die $!;
    local $/;
    my $source = <$fh>;
    close $fh;

    my ($unknown_block) = $source =~ /if \s*\(\@unknown_token\)\s*\{(.*?)\n    \}/xs;
    ok( defined $unknown_block, 'found the unknown_token warning block in cli/poller.pl' );

    unlike( $unknown_block, qr/almost certainly a sibling project/,
        'the unknown-token branch never reuses the different-token branch\'s confident wording' );
    like( $unknown_block, qr/could not be/,
        'the unknown-token branch is explicit that the token comparison itself could not be made' );
    like( $unknown_block, qr/cross-checked/,
        'the unknown-token branch names the cross-check that could not be performed' );
}

done_testing();
