use strict;
use warnings;

use PostgresNode;
use TestLib;
use Test::More;
use IPC::Run qw(pump finish timer);
use Data::Dumper;

if (!defined($ENV{with_readline}) || $ENV{with_readline} ne 'yes')
{
	plan skip_all => 'readline is not supported by this build';
}

# If we don't have IO::Pty, forget it, because IPC::Run depends on that
# to support pty connections
eval { require IO::Pty; };
if ($@)
{
	plan skip_all => 'IO::Pty is needed to run this test';
}

# start a new server
my $node = get_new_node('main');
$node->init;
$node->start;

# set up a few database objects
$node->safe_psql('postgres',
	    "CREATE TABLE tab1 (f1 int, f2 text);\n"
	  . "CREATE TABLE mytab123 (f1 int, f2 text);\n"
	  . "CREATE TABLE mytab246 (f1 int, f2 text);\n");

# Developers would not appreciate this test adding a bunch of junk to
# their ~/.psql_history, so be sure to redirect history into a temp file.
# We might as well put it in the test log directory, so that buildfarm runs
# capture the result for possible debugging purposes.
my $historyfile = "${TestLib::log_path}/010_psql_history.txt";
$ENV{PSQL_HISTORY} = $historyfile;

# Debug investigation
note "TERM is set to '" . ($ENV{TERM} || "<undef>") . "'";

# regexp to match one xterm escape sequence (CSI style only, for now)
my $escseq = "(\e\\[[0-9;]*[A-Za-z])";

# fire up an interactive psql session
my $in  = '';
my $out = '';

my $timer = timer(5);

my $h = $node->interactive_psql('postgres', \$in, \$out, $timer);

ok($out =~ /psql/, "print startup banner");

# Simple test case: type something and see if psql responds as expected
sub check_completion
{
	my ($send, $pattern, $annotation) = @_;

	# report test failures from caller location
	local $Test::Builder::Level = $Test::Builder::Level + 1;

	# reset output collector
	$out = "";
	# restart per-command timer
	$timer->start(5);
	# send the data to be sent
	$in .= $send;
	# wait ...
	pump $h until ($out =~ m/$pattern/ || $timer->is_expired);
	my $okay = ($out =~ m/$pattern/ && !$timer->is_expired);
	ok($okay, $annotation);
	# for debugging, log actual output if it didn't match
	local $Data::Dumper::Terse = 1;
	local $Data::Dumper::Useqq = 1;
	diag 'Actual output was ' . Dumper($out) . "\n" if !$okay;
	return;
}

# Clear query buffer to start over
# (won't work if we are inside a string literal!)
sub clear_query
{
	check_completion("\\r\n", "postgres=# ", "\\r works");
	return;
}

# check basic command completion: SEL<tab> produces SELECT<space>
check_completion("SEL\t", "SELECT ", "complete SEL<tab> to SELECT");

clear_query();

# check case variation is honored
check_completion("sel\t", "select ", "complete sel<tab> to select");

# check basic table name completion
check_completion("* from t\t", "\\* from tab1 ", "complete t<tab> to tab1");

clear_query();

# check table name completion with multiple alternatives
# note: readline might print a bell before the completion
check_completion(
	"select * from my\t",
	"select \\* from my\a?tab",
	"complete my<tab> to mytab when there are multiple choices");

# some versions of readline/libedit require two tabs here, some only need one.
# also, some might issue escape sequences to reposition the cursor, clear the
# line, etc, instead of just printing some spaces.
check_completion(
	"\t\t",
	"mytab$escseq*123( |$escseq)+mytab$escseq*246",
	"offer multiple table choices");

check_completion("2\t", "246 ",
	"finish completion of one of multiple table choices");

clear_query();

# check case-sensitive keyword replacement
# note: various versions of readline/libedit handle backspacing
# differently, so just check that the replacement comes out correctly
check_completion("\\DRD\t", "drds ", "complete \\DRD<tab> to \\drds");

clear_query();

# send psql an explicit \q to shut it down, else pty won't close properly
$timer->start(5);
$in .= "\\q\n";
finish $h or die "psql returned $?";
$timer->reset;

# done
$node->stop;
done_testing();