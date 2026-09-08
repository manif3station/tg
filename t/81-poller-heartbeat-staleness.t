use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Config;

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
        open my $fh, '>', $heartbeat_path or die $!;
        print {$fh} time() - 3600;
        close $fh;

        my $out = `$status_cli`;
        like( $out, qr/heartbeat: \d+s ago \(STALE\)/, 'd2 tg.status flags an hour-old heartbeat as STALE' );

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
