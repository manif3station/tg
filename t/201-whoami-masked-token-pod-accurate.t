use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-201 (found via a scheduled JOB-003 hourly bug hunt,
# documentation-accuracy defect, not a code defect): cli/whoami.pl's
# own POD, lines ~97-99, describes D2TG::Config::masked_token's
# short-token behavior as "shown as-is, unmasked" - this was true
# before TGT-138, but TGT-138 already fixed masked_token to return a
# fixed '(short token, not shown)' placeholder instead for any token
# of length <= 8. This is a structural (source-inspection) regression
# test, not a functional one - there is no injectable seam for "does
# this POD sentence match the real code behavior" other than the
# source text itself, matching this project's own established
# precedent (t/104, t/88, t/195, t/198).

my $whoami_path = File::Spec->catfile( $Bin, '..', 'cli', 'whoami.pl' );
my $whoami_src  = _slurp($whoami_path);

# The stale claim must be gone.
unlike(
    $whoami_src,
    qr/shown as-is,\s*unmasked/i,
    "cli/whoami.pl's POD no longer claims a short token is shown as-is/unmasked"
);

# The current, correct behavior must be described instead.
like(
    $whoami_src,
    qr/\(short token, not shown\)/,
    "cli/whoami.pl's POD names the actual fixed placeholder masked_token returns for a short token"
);

# The fixed placeholder text must match D2TG::Config::masked_token's
# own real return value exactly - this is what makes the test a
# genuine accuracy check, not just a check that SOME text changed.
my $config_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Config.pm' );
my $config_src  = _slurp($config_path);
like(
    $config_src,
    qr/\(short token, not shown\)/,
    'sanity check: D2TG::Config.pm itself really does return this exact placeholder text'
);

# No other doc/POD in the repo repeats the stale claim AS CURRENT FACT.
# README.md/Changes are changelog-style and legitimately narrate the
# stale wording as history when describing what TGT-201 fixed (e.g.
# "described ... as 'shown as-is, unmasked' - true before TGT-138") -
# that is not itself a live copy of the defect, so only flag an
# occurrence that isn't accompanied by nearby TGT-138/history context.
for my $rel (qw(docs/commands.md docs/POLICIES.md README.md SKILLS.md)) {
    my $path = File::Spec->catfile( $Bin, '..', $rel );
    next unless -f $path;
    my $src = _slurp($path);
    # /s so the lookahead's "." can cross the line wrap between the
    # stale phrase and its own "- true before TGT-138" qualifier in
    # README.md's prose - without it, a multi-line changelog entry
    # would false-positive as a bare (unqualified) stale claim.
    my $bare_stale_claim_re = qr/
        shown \s+ as-is,\s*unmasked
        (?! .{0,120} TGT-138 )
    /isxs;
    unlike( $src, $bare_stale_claim_re, "$rel does not repeat the stale claim as current fact" );
}

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "can't open $path: $!";
    local $/;
    return <$fh>;
}
