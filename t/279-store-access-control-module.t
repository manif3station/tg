use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-279 (own follow-up filed by TGT-278's survey): continuing
# D2TG::Store.pm's decomposition - the access-control cluster
# (is_allowed/add_pending/approve/pending_chat_ids/seed_admin, all of
# which only need the shared $dbh) moved into a new
# D2TG::Store::AccessControl module, mirroring D2TG::Store::RetryQueue/
# History's own established DBI-handle-wrapper precedent.

require D2TG::Store;
require D2TG::Store::AccessControl;

for my $name (qw(is_allowed add_pending approve pending_chat_ids seed_admin)) {
    ok( D2TG::Store::AccessControl->can($name), "D2TG::Store::AccessControl owns $name" );
}

done_testing();
