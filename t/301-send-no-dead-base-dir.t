use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-301 (found via a user-requested comprehensive bug/improvement
# sweep): cli/send.pl's own
# D2TG::Config::resolve_and_require_base_dir_or_die(alias => $db_alias)
# call computed base_dir but it was never used anywhere else in the
# file - send.pl never opens a Store and never touches
# attachments_dir, it's a pure Telegram-API passthrough. The --db
# validation itself still has a real side effect (requires the alias
# to resolve to an existing directory before any network call), so
# per this ticket's own acceptance criteria the call is kept (not
# removed) but no longer assigned to a variable nothing reads, and an
# explicit comment now states why.

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

unlike( $source, qr/my \$base_dir = D2TG::Config::resolve_and_require_base_dir_or_die/,
    'the resolved base_dir is no longer assigned to an unused variable' );

like( $source, qr/D2TG::Config::resolve_and_require_base_dir_or_die\( alias => \$db_alias \);/,
    'the --db validation call itself is still made (its side effect - requiring the alias to resolve - is real)' );

like( $source, qr/side effect|only for its side effect|validation only/i,
    'an explicit comment explains why the resolved value is unused' );

done_testing();
