use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Poller;
require D2TG::Config;

# TGT-175 (live production incident, reported via the budget project):
# cli/poller.pl's main-loop version-change check calls
# D2TG::Config::skill_version() directly, unwrapped - a transient
# window where .env is briefly missing/unreadable during the skill's
# own self-update (an install rewriting the directory mid-flight) is
# fatal to the ENTIRE poller process, not just to that one version
# check. skill_version_check_safe wraps it, matching
# persist_offset_safe's (TGT-166) own established non-fatal-
# degradation pattern - the poller's core loop does not need to know
# the skill's version to keep running.

sub capture_stderr {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    local *STDERR = $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

{
    my $skill_root = tempdir( CLEANUP => 1 );
    open my $fh, '>', File::Spec->catfile( $skill_root, '.env' ) or die $!;
    print {$fh} "VERSION=1.99\n";
    close $fh;

    my $version = D2TG::Poller::skill_version_check_safe( default_root => $skill_root );
    is( $version, '1.99', 'skill_version_check_safe returns the version on success, same as skill_version' );
}

{
    my $skill_root = tempdir( CLEANUP => 1 );

    # .env genuinely missing - simulates the exact TGT-175 incident (a
    # transient window during the skill directory's own self-update).
    my $stderr;
    my $version;
    $stderr = capture_stderr( sub { $version = D2TG::Poller::skill_version_check_safe( default_root => $skill_root ) } );

    is( $version, undef, 'skill_version_check_safe returns undef, not dying, when .env is transiently missing' );
    like( $stderr, qr/skill_version_check_safe:.*\.env.*skipping this cycle.*will retry next cycle/is,
        'the STDERR line names the underlying .env error and says the check is being skipped and retried, not just that something failed' );
}

{
    # Confirm skill_version itself (the startup call site's own
    # dependency) is completely unchanged - it must still die loudly,
    # since a fresh process launch with no readable .env at all should
    # refuse to start, not silently proceed with an unknown version.
    my $skill_root = tempdir( CLEANUP => 1 );
    eval { D2TG::Config::skill_version( default_root => $skill_root ) };
    like( $@, qr/\.env/, 'skill_version itself (unwrapped) still dies loudly - only the new wrapper changes behavior, not the underlying function' );
}

done_testing();
