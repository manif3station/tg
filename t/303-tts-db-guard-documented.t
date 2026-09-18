use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-303 (found via a user-requested comprehensive bug/improvement
# sweep): unlike cli/help.pl, which explicitly documents why TGT-059's
# mandatory --db/-d/D2TG_DB guard doesn't apply to it, cli/tts.pl also
# skips that guard (never calls extract_db_flag_or_die/
# resolve_and_require_base_dir_or_die) but never stated why in its own
# POD - a reader had to infer it from the absence of the call rather
# than being told, matching help.pl's own established precedent.

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'tts.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

like( $source, qr/--db.{0,10}-d.{0,10}D2TG_DB/s,
    "tts.pl's own POD explicitly names the --db/-d/D2TG_DB guard" );

like( $source, qr/does\s+not\s+apply|does\s+not\s+require|no\s+--db|doesn't\s+require/i,
    "tts.pl's own POD explicitly states the guard does not apply, matching help.pl's precedent" );

done_testing();
