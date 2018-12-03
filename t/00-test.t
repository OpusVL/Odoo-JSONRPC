use Test::Most;

use lib::relative 'lib';

use Test::UserAgent;

use_ok 'Odoo::JSONRPC';

my $odoo = Odoo::JSONRPC->new(
    ua => Test::UserAgent->new
);

throws_ok { $odoo->login('testdb', 'testuser', 'testpass') }
    'failure::odoo::jsonrpc::invalid_credentials', "Bad login throws";
lives_ok { $odoo->login('testdb', 'admin', 'admin') }
    "Correct login works";
