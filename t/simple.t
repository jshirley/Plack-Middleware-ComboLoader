use strict;
use warnings;

use Test::More;
use Plack::Test;

use HTTP::Request::Common;

use_ok('Plack::Middleware::ComboLoader');

my $loader = Plack::Middleware::ComboLoader->new({
    roots => {
        't1'     => 't/static/js',
        't1/css' => 't/static/css'
    }
});

$loader->wrap( sub {
    [ 200, [ 'Content-Type' => 'text/plain' ], [ 'app' ] ]
});

test_psgi $loader => sub {
    my $server = shift;
    subtest "simple concat" => sub {
        my $res = $server->(GET '/t1?foo.js&bar.js');
        ok($res->is_success, 'valid request');
        is($res->content, qq{var foo = 1;\nvar bar = 2;\n}, 'right content');
    };

    subtest "missing files" => sub {
        my $res = $server->(GET '/t1?foo.js&missing.js');
        # Don't rely on HTTPExceptiosn in the unit test, so this will come out
        # as a 500 instead of a 400.
        is($res->code, 500, 'bad request');
        is($res->content, q{400 Bad Request Invalid resource requested: `missing.js` is not available.}, 'right error message');
    };
};

done_testing;