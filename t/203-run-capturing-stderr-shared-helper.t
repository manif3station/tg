use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-203 (found via a scheduled JOB-004 improvement hunt): the exact
# same 8-line run_capturing_stderr($telegram_cli_cmd) helper was
# hand-copied into 6 separate test files - byte-for-byte identical
# except each file's own hardcoded /tmp/d2tg-NNN-stderr.$$ suffix.
# Matches this project's own established "found it twice, extract it"
# duplication-removal precedent, just in test infrastructure this
# time. This is a structural (source-inspection) regression test, not
# a functional one - matching this project's own established
# precedent (t/104, t/88, t/195, t/198) since "is this defined locally
# vs. imported from the shared module" has no other injectable seam.

my @affected_files = qw(
    59-db-flag-requires-value.t
    77-poller-unrecognized-flag-refuses.t
    183-poller-store-startup-crash.t
    184-poller-lock-heartbeat-path-startup-crash.t
    185-poller-lock-leak-no-groups-and-store-failure.t
    186-cli-store-startup-crash.t
);

my $capture_stdio_path = File::Spec->catfile( $Bin, 'lib', 'Test', 'CaptureStdio.pm' );
my $capture_stdio_src  = _slurp($capture_stdio_path);

like(
    $capture_stdio_src,
    qr/^sub run_capturing_stderr \{/m,
    'Test::CaptureStdio defines a shared run_capturing_stderr helper'
);

like(
    $capture_stdio_src,
    qr/EXPORT_OK.*run_capturing_stderr/s,
    'run_capturing_stderr is exported alongside capture_stdio'
);

for my $file (@affected_files) {
    my $path = File::Spec->catfile( $Bin, $file );
    my $src  = _slurp($path);

    unlike(
        $src,
        qr/^sub run_capturing_stderr \{/m,
        "$file no longer defines its own local run_capturing_stderr"
    );

    like(
        $src,
        qr/Test::CaptureStdio\b.*run_capturing_stderr/s,
        "$file imports run_capturing_stderr from the shared module "
          . "(either 'use Test::CaptureStdio qw(...)' directly, or "
          . "t/59's own require-by-path + explicit ->import, needed "
          . "there to avoid polluting \@INC for its own unrelated "
          . "Developer::Dashboard availability SKIP-gate check)"
    );
}

# t/202's own intentionally-different fork+setpgrp+timeout helper must
# stay separate - not folded into this extraction, since it solves a
# different problem (a subprocess that can hang indefinitely).
my $t202_path = File::Spec->catfile( $Bin, '202-duplicate-bot-pair-refused.t' );
if ( -f $t202_path ) {
    my $t202_src = _slurp($t202_path);
    like(
        $t202_src,
        qr/setpgrp/,
        "t/202's own fork+setpgrp+timeout helper is untouched by this extraction"
    );
}

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "can't open $path: $!";
    local $/;
    return <$fh>;
}
