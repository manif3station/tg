use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-280 (own follow-up filed by TGT-279's survey): D2TG::Store.pm was
# still 574 lines, entirely due to _ensure_schema (355 lines) - a
# single large schema/migration function tightly coupled to new(), not
# a set of independent methods sharing only $dbh like every prior
# extraction this session. Extracted into a new D2TG::Store::Schema
# module exposing a single ensure_schema($dbh) function, preserving
# exact migration call order (later migrations depend on
# columns/tables earlier ones create).

require D2TG::Store;
require D2TG::Store::Schema;

ok( D2TG::Store::Schema->can('ensure_schema'), "D2TG::Store::Schema owns ensure_schema" );

done_testing();
