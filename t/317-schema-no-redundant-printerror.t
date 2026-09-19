use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-317 (found via a scheduled JOB-004 improvement hunt, reviewing
# TGT-316's own freshly-shipped diff): TGT-316 made D2TG::Store::new's
# DBI connection default PrintError to 0. D2TG::Store::Schema.pm's own
# 6 "local $dbh->{PrintError} = 0;" blocks became pure no-ops at that
# point - dead weight that could mislead a future reader into thinking
# per-call suppression is still needed. Removed here; source-inspection
# regression test, matching this project's own established precedent
# for a pure-cleanup ticket with no behavioral test to write.

my $module_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Store', 'Schema.pm' );
open my $fh, '<', $module_path or die "can't read $module_path: $!";
local $/;
my $source = <$fh>;
close $fh;

unlike( $source, qr/local \$dbh->\{PrintError\}/,
    'D2TG::Store::Schema.pm no longer sets any local PrintError override - the connection-level default (TGT-316) covers it' );

done_testing();
