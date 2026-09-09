use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Config;
require D2TG::Transcribe;

# TGT-147, a Codex review finding: hard-coding the expected threshold
# (14400) here would recreate the exact failure mode this ticket
# exists to fix - a future change to D2TG::Transcribe's own
# TIMEOUT_CEILING/MODEL_TIERS would silently desync this test from the
# real derivation instead of catching it. Compute the expected value
# from the same source constants cli/status.pl itself derives from.
my $expected_stale_threshold =
  int( $D2TG::Transcribe::TIMEOUT_CEILING * scalar(@D2TG::Transcribe::MODEL_TIERS) * 4 / 3 );

# TGT-116 (re-scoped during drafting: a genuinely stuck poller can't
# restart itself, so full auto-restart needs an external actor - an
# operational/architecture decision, not pure code. This ticket
# delivers detection only): cli/poller.pl writes a heartbeat once per
# full poll cycle, regardless of message/error activity, so "the loop
# is still cycling" is distinguishable from "genuinely wedged" - the
# exact ambiguity that let an 80+ minute real message loss go
# undetected earlier this session.

{
    my $dir = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'telegram.heartbeat' );

    is( D2TG::Config::heartbeat_age($path), undef, 'heartbeat_age returns undef when no heartbeat file exists yet' );

    D2TG::Config::write_heartbeat($path);
    ok( -e $path, 'write_heartbeat creates the file' );

    my $age = D2TG::Config::heartbeat_age($path);
    ok( defined $age, 'heartbeat_age returns a defined value once a heartbeat has been written' );
    ok( $age < 5, 'a freshly-written heartbeat is reported as very recent (< 5s old)' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'telegram.heartbeat' );

    open my $fh, '>', $path or die $!;
    print {$fh} time() - 3600;    # 1 hour old
    close $fh;

    my $age = D2TG::Config::heartbeat_age($path);
    ok( $age >= 3599 && $age <= 3601, 'heartbeat_age correctly reports an old heartbeat as old (~3600s)' );
}

{
    # heartbeat_path mirrors lock_path's own base_dir/.tira resolution
    # exactly, so it lands in the same vault, not a separate location.
    my $base_dir = tempdir( CLEANUP => 1 );
    my $path = D2TG::Config::heartbeat_path( base_dir => $base_dir );

    is( $path, File::Spec->catfile( $base_dir, '.tira', 'telegram.heartbeat' ),
        'heartbeat_path resolves under the same .tira/ vault as lock_path' );
}

{
    # Mirrors lock_path's own default_root/state/poller.pid fallback
    # (t/40-db-alias-resolution.t) - no base_dir given at all.
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = D2TG::Config::heartbeat_path( default_root => $dir );

    is( $path, File::Spec->catfile( $dir, 'state', 'poller.heartbeat' ),
        'heartbeat_path without base_dir falls back to default_root/state/poller.heartbeat, mirroring lock_path' );
    ok( -d File::Spec->catdir( $dir, 'state' ), 'heartbeat_path creates the state/ directory if missing' );
}

# CLI-level: d2 tg.status reports heartbeat staleness.
{
    my $status_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'status.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $heartbeat_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.heartbeat' );

    {
        my $out = `$status_cli`;
        like( $out, qr/heartbeat: never/i, 'd2 tg.status reports "never" when no heartbeat has ever been written' );
    }

    {
        mkdir File::Spec->catdir( $fake_db_dir, '.tira' );
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time();
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(ok\)/, 'd2 tg.status reports a fresh heartbeat as ok' );
        unlike( $out, qr/stale/i, 'a fresh heartbeat is never flagged stale' );
    }

    {
        # TGT-147: STALE_THRESHOLD_SECONDS is now 14400s (4h), not
        # 1200s (20m) - derived from D2TG::Transcribe's own worst-case
        # timeout math (TGT-140's scaled per-tier timeout, up to
        # 3600s, times 3 retry-ladder tiers, with the same ~1.33x
        # safety margin the original threshold used) after a scheduled
        # bug hunt caught the original flat-1200s assumption going
        # stale the moment TGT-140 shipped in this same session. An
        # hour-old heartbeat is comfortably still healthy under the
        # new threshold - no longer STALE the way it was before this
        # ticket, since a single still-transcribing bot/chat pair can
        # now legitimately take far longer than an hour.
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time() - 3600;
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(ok\)/, 'an hour-old heartbeat is comfortably ok under the new 14400s threshold, not STALE' );

        unlink $heartbeat_path;
    }

    {
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time() - ( $expected_stale_threshold + 3600 );
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(STALE\)/, 'a heartbeat an hour past the derived threshold is flagged STALE' );

        unlink $heartbeat_path;
    }

    # Codex review finding: pin down that the boundary is near the
    # derived threshold, not just "well past it is stale" - close
    # enough on both sides to prove the threshold actually moved off
    # the old 1200s value, with a few seconds' margin either side of
    # the exact boundary so real subprocess-exec latency between
    # writing the heartbeat and d2 tg.status reading it can never flip
    # the result (an exact time()-threshold write can legitimately
    # read back as 1s older by the time the CLI subprocess actually
    # runs). Computed from the same source constants as cli/status.pl
    # itself (a second Codex finding) rather than a hard-coded literal,
    # so this test can't silently desync from the real derivation if
    # D2TG::Transcribe's own constants ever change.
    {
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time() - ( $expected_stale_threshold - 10 );
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(ok\)/, 'a heartbeat just under the derived threshold is still ok, not STALE' );

        unlink $heartbeat_path;
    }

    {
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time() - ( $expected_stale_threshold + 10 );
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(STALE\)/, 'a heartbeat just over the derived threshold flips to STALE' );

        unlink $heartbeat_path;
    }
}

# Codex review finding: write_heartbeat's non-atomic '>' truncate could
# transiently or permanently show "never" on a concurrent read or a
# crash mid-write. Verify the fix: it writes via a temp file + rename,
# leaves no stray temp file behind, and correctly overwrites an existing
# heartbeat (not just creates a fresh one).
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'telegram.heartbeat' );

    D2TG::Config::write_heartbeat($path);
    my $first_age = D2TG::Config::heartbeat_age($path);
    ok( defined $first_age, 'first write_heartbeat call produces a readable heartbeat' );

    D2TG::Config::write_heartbeat($path);
    my $second_age = D2TG::Config::heartbeat_age($path);
    ok( defined $second_age, 'write_heartbeat overwrites an existing heartbeat file, still readable' );

    opendir my $dh, $dir or die $!;
    my @leftover_tmp = grep { /\.tmp\.\d+$/ } readdir $dh;
    closedir $dh;
    is_deeply( \@leftover_tmp, [], 'write_heartbeat leaves no stray .tmp.<pid> file behind' );
}

# Codex review finding: this file exercised D2TG::Config and cli/status.pl
# directly, but never confirmed the real call site in cli/poller.pl's
# main loop - it would still pass even if the write_heartbeat() call
# were misplaced, made conditional, or removed. Structurally verify the
# call sits inside the per-pair for-loop (so a heartbeat is written
# after EACH bot/chat pair's own run_once_safe/set_offset, not only once
# after the whole loop finishes) - the fix for the "a healthy poller can
# be reported STALE" finding above.
{
    my $poller_path = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );
    open my $fh, '<', $poller_path or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    ok(
        $source =~ /for\s+my\s+\$pair\s*\(\@pairs\)\s*\{.*?write_heartbeat\(\$heartbeat_path\);/s,
        'cli/poller.pl calls write_heartbeat(...) inside the per-pair for-loop, not only after it'
    );

    ok(
        $source =~ /write_heartbeat\(\$heartbeat_path\);\s*\}\s*D2TG::Download::prune_vault/s,
        'the per-pair heartbeat write happens before prune_vault, still inside the pair loop body'
    );
}

done_testing();
