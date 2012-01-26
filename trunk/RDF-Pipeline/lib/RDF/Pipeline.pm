#! /usr/bin/perl -w 
package RDF::Pipeline;

# RDF Pipeline Framework
# Copyright 2011 & 2012 David Booth <david@dbooth.org>
# Code home: http://code.google.com/p/rdf-pipeline/
# See license information at http://code.google.com/p/rdf-pipeline/ 

# Command line test (cannot currently be used, due to bug #9 fix):
#  MyApache2/Chain.pm --test --debug http://localhost/hello
# To restart apache (under root):
#  apache2ctl stop ; sleep 5 ; truncate -s 0 /var/log/apache2/error.log ; apache2ctl start

use 5.10.1; 	# It *may* work under lower versions, but has not been tested.
use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use RDF::Pipeline ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	
);

our $VERSION = '0.01';


# Preloaded methods go here.

#file:MyApache2/Chain.pm
#----------------------
# Apache2 uses multiple threads and a pool of PerlInterpreters.
# Code below that is outside of any function will be executed once
# for each PerlInterpreter instance when it starts.  Since existing
# PerlInterpreter instances will be used first, a new instance will 
# only be started when all existing instances are busy.  Also, in
# spite of being threaded, variables are separate between 
# instances -- mod_perl does this somehow -- so one instance will not see
# changes made to another instance's variables unless something
# special is done to make them shared.  (Maybe threads::shared?
# Or Apache::Session::File?)  This means that HTTP response headers
# cannot be cached in memory (without doing something special),
# because they won't be visible across thread instances.

# See http://perl.apache.org/docs/2.0/user/intro/start_fast.html
use Carp;
# use diagnostics;
use Apache2::RequestRec (); # for $r->content_type
use Apache2::SubRequest (); # for $r->internal_redirect
use Apache2::RequestIO ();
# use Apache2::Const -compile => qw(OK SERVER_ERROR NOT_FOUND);
use Apache2::Const -compile => qw(:common REDIRECT HTTP_NO_CONTENT DIR_MAGIC_TYPE HTTP_NOT_MODIFIED);
use Apache2::Response ();
use APR::Finfo ();
use APR::Const -compile => qw(FINFO_NORM);
use Apache2::RequestUtil ();
use Apache2::Const -compile => qw( HTTP_METHOD_NOT_ALLOWED );
use Fcntl qw(LOCK_EX O_RDWR O_CREAT);

use HTTP::Date;
use APR::Table ();
use LWP::UserAgent;
use HTTP::Status;
use Apache2::URI ();
use URI::Escape;
use Time::HiRes ();
use File::Path qw(make_path remove_tree);
use WWW::Mechanize;

# $debug levels:
#	0	No debugging.  Warnings/errors only.
#	1	Show what was updated.  This level should be good for testing.
#	2	Show more detail of what happened.
my $debug = 1;
my $test;

my $prefix = "http://purl.org/pipeline/ont#";	# Pipeline ont prefix
$ENV{DOCUMENT_ROOT} ||= "/home/dbooth/rdf-pipeline/trunk/www";	# Set if not set
### TODO: Set $baseUri properly.  Needs port?
$ENV{SERVER_NAME} ||= "localhost";
# $baseUri is the URI prefix that corresponds directly to DOCUMENT_ROOT.
my $baseUri = "http://$ENV{SERVER_NAME}";  # TODO: Should become "scope"?
my $baseUriPattern = quotemeta($baseUri);
my $basePath = $ENV{DOCUMENT_ROOT};	# Synonym, for convenience
my $basePathPattern = quotemeta($basePath);
my $nodeBaseUri = "$baseUri/node";	# Base for nodes
my $nodeBaseUriPattern = quotemeta($nodeBaseUri);
my $nodeBasePath = "$basePath/node";
my $nodeBasePathPattern = quotemeta($nodeBasePath);
my $lmCounterFile = "$basePath/lm/lmCounter.txt";
my $THIS_URI = "THIS_URI"; # Env var name to use
my $rdfsPrefix = "http://www.w3.org/2000/01/rdf-schema#";
# my $subClassOf = $rdfsPrefix . "subClassOf";
my $subClassOf = "rdfs:subClassOf";

my $configFile = "$nodeBasePath/pipeline.n3";
my $ontFile = "$basePath/ont/ont.n3";
my $internalsFile = "$basePath/ont/internals.n3";

my $logFile = "/tmp/rdf-pipeline-log.txt";
# unlink $logFile || die;

my %config = ();		# Maps: "?s ?p" --> "v1 v2 ... vn"
my %configValues = ();		# Maps: "?s ?p" --> {v1 => 1, v2 => 1, ...}

# Node Metadata hash maps for mapping from subject
# to predicate to single value ($nmv), list ($nml) or hashmap ($nmh).  
#  For single-valued predicates:
#    my $nmv = $nm->{value};	
#    my $value = $nmv->{$subject}->{$predicate};
#  For list-valued predicates:
#    my $nml = $nm->{list};	
#    my $listRef = $nml->{$subject}->{$predicate};
#    my @list = @{$listRef};
#  For hash or multi-valued predicates:
#    my $nmh = $nm->{hash};	
#    my $hashRef = $nmh->{$subject}->{$predicate};
#    # Multi-valued (maps to 1 if present):
#    if ($hashRef->{$someValue}) { ... }
#    # Hash valued (maps a key to a value):
#    my $value = $hashRef->{$key};
my $nm = {"value"=>{}, "list"=>{}, "hash"=>{}};

my %cachedResponse = ();	# Previous HTTP response to GET or HEAD.
				# Key: "$thisUri $supplierUri"
my $configLastModified = 0;
my $ontLastModified = 0;
my $internalsLastModified = 0;

&Warn("="x30 . " START9 " . "="x30 . "\n", 2);
&Warn("  " . `date`, 2);
&Warn("  SERVER_NAME: $ENV{SERVER_NAME}\n", 2);
&Warn("  DOCUMENT_ROOT: $ENV{DOCUMENT_ROOT}\n", 2);
# my $hasHiResTime = &Time::HiRes::d_hires_stat()>0 ? "true" : "false";
# &Warn("Has HiRes time: $hasHiResTime\n", 2);

if (0)
	{
	# Code for testing shared session data:
	  use Apache::Session::File;
	my $sessionsDir = '/tmp/rdf-pipeline-sessions';
	my $locksDir = '/tmp/rdf-pipeline-locks';

	-d $sessionsDir || mkdir($sessionsDir) || die;
	-d $locksDir || mkdir($locksDir) || die;

	  my %session;
	  my $sessionIdFile = "/tmp/rdf-pipeline-sessionID";
	  my $sessionId = &ReadFile($sessionIdFile);
	  $sessionId = undef if !$sessionId;
	  my $isNewSessionId = !$sessionId;
	  #make a fresh session for a first-time visitor
	 tie %session, 'Apache::Session::File', $sessionId, {
	    Directory => $sessionsDir,
	    LockDirectory   => $locksDir,
	 };
	$sessionId ||= $session{_session_id};

	&WriteFile($sessionIdFile, $sessionId) if $isNewSessionId;
	&Warn("sessionId: $sessionId\n", 2);

	  #...time passes...

	$session{date} ||= `date`;
	my $testShared = $session{date};
	&Warn("testShared: $testShared\n", 2);
	}

use Getopt::Long;

&GetOptions("test" => \$test,
	"debug" => \$debug,
	);
&Warn("  ARGV: @ARGV\n", 2) if $test || $debug;

&RegisterWrappers($nm);

my $testUri = shift @ARGV || "http://localhost/chain";
my $testArgs = "";
if ($testUri =~ m/\A([^\?]*)\?/) {
	$testUri = $1;
	$testArgs = $';
	}
if ($test)
	{
	die "COMMAND-LINE TESTING IS NO LONGER IMPLEMENTED!\n";
	# Invoked from the command line, instead of through Apache.
	# Fake a RequestReq object:
	my $r = &MakeFakeRequestReq();
	$r->content_type('text/plain');
	$r->args($testArgs || "");
	$r->set_content_length(0);
	$r->set_content_length(time);
	$r->method("GET");
	$r->header_only(0);
	$r->meets_conditions(1);
	$r->construct_url($testUri); 
	$testUri =~ m|\Ahttp(s?)\:\/\/[^\/]+\/| or die;
	my $path = "/" . $';
	$r->uri($path);
	my $code = &handler($r);
	&Warn("\nHandler returned code: $code\n", 2);
	exit 0;
	}

#######################################################################
###################### Functions start here ###########################
#######################################################################

############### MakeFakeRequestRec ###############
# I started writing this, but abandoned it because I'm not sure it is needed.
# Its only purpose was to allow simple testing from the command line, but
# I think it may be easier to set up a test harness and to all testing
# through Apache.
sub MakeFakeRequestReq
{
# Fake a RequestRec object.
# This did NOT work:
# my $r = Apache2::RequestRec->Apache2::RequestRec::new(undef); # Will this work?
# See: http://www.perlmonks.org/?node_id=667221
my $r = Test::MockObject->new();
$r->mock( pool => sub { return APR::Pool->new; } );
my @setterGetters = qw( uri content_type construct_url args
	set_content_length set_last_modified method header_only
	meets_conditions sendfile headers_in headers_out internal_redirect );
foreach my $sg (@setterGetters) {
	$r->mock( $sg => sub { my $r=shift; return @_ ? $r->{$sg}=shift : $r->{$sg}; } );
	}
my $hi = Test::MockObject->new();
$hi->mock( set => sub { my $r=shift; return @_ ? $r->{set}=shift : $r->{set}; } );
$hi->mock( get => sub { my $r=shift; return @_ ? $r->{get}=shift : $r->{get}; } );
$r->headers_in($hi);
my $ho = Test::MockObject->new();
$ho->mock( set => sub { my $r=shift; return @_ ? $r->{set}=shift : $r->{set}; } );
$ho->mock( get => sub { my $r=shift; return @_ ? $r->{get}=shift : $r->{get}; } );
$r->headers_out($ho);
return $r;
}

##################### handler #######################
# handler will be called by apache2 to handle any request that has
# been specified in /etc/apache2/sites-enabled/000-default .
sub handler
{
# &Warn("-"x20 . "handler" . "-"x20 . "\n", 2);
my $ret = &RealHandler(@_);
&Warn("RealHandler returned: $ret\n", 2);
return $ret;
}

##################### RealHandler #######################
sub RealHandler 
{
my $r = shift || die;
# $debug = ($r && $r->uri =~ m/c\Z/);
# $r->content_type('text/plain') if $debug && !$test;
&Warn("RealHandler called: " . `date`, 2);
if (0 && $debug) {
	&Warn("  Environment variables:\n", 2);
	foreach my $k (sort keys %ENV) {
		&Warn("    $k = " . $ENV{$k} . "\n", 2);
		}
	&Warn("\n", 2);
	}
my $thisUri = $testUri;
# construct_url omits the query params though
$thisUri = $r->construct_url() if !$test; 
&Warn("  thisUri: $thisUri\n", 2);

# Reload config file?
my $cmtime = &MTime($configFile);
my $omtime = &MTime($ontFile);
my $imtime = &MTime($internalsFile);
if ($configLastModified != $cmtime
		|| $ontLastModified != $omtime
		|| $internalsLastModified != $imtime) {
	# Reload config file.
	&Warn("  Reloading config file: $configFile\n", 2);
	$configLastModified = $cmtime;
	$ontLastModified = $omtime;
	$internalsLastModified = $imtime;
	if (1) {
		%config = &CheatLoadN3($ontFile, $configFile);
		%configValues = map { 
			my $hr; 
			map { $hr->{$_}=1; } split(/\s+/, ($config{$_}||"")); 
			($_, $hr)
			} keys %config;
		# &Warn("  configValues:\n", 2);
		foreach my $sp (sort keys %configValues) {
			last if !$debug;
			my $hr = $configValues{$sp};
			foreach my $v (sort keys %{$hr}) {
				# &Warn("    $sp $v\n", 2);
				}
			}
		}
	&LoadNodeMetadata($nm, $ontFile, $configFile);
	&PrintNodeMetadata($nm) if $debug;

	# &Warn("  Got here!\n", 2); 
	# return Apache2::Const::OK;
	# %config || return Apache2::Const::SERVER_ERROR;
	}

my $thisVHash = $nm->{value}->{$thisUri} || {};
my $subtype = $thisVHash->{nodeType} || "";
&Warn("  WARNING: $thisUri is not a Node.  types: \n") if !$subtype;
&Warn("  thisUri: $thisUri subtype: $subtype\n", 2);
# Allow non-node files in the www/node/ dir to be served normally:
return Apache2::Const::DECLINED if !$subtype;
# return Apache2::Const::NOT_FOUND if !$subtype;
return &HandleHttpEvent($nm, $r);
}

################### ForeignSendHttpRequest ##################
# Send a remote GET, GRAB or HEAD to $depUri if $depLM is newer than 
# the stored LM of $thisUri's local serNameUri LM for $depLM.
# The reason for checking $depLM here instead of checking it in
# &RequestLatestDependsOns(...) is because the check requires a call to
# &LookupLMs($inSerNameUri), which needs to be done here anyway
# in order to look up the old LM headers.
# Also remember that $depUri is not necessarily a node: it may be 
# an arbitrary URI source.
# We cannot count on LMs to be monotonic, because they could be
# checksums or such.
sub ForeignSendHttpRequest
{
@_ == 5 or die;
my ($nm, $method, $thisUri, $depUri, $depLM) = @_;
&Warn("ForeignSendHttpRequest(nm, $method, $thisUri, $depUri, $depLM) called\n", 2);
# Send conditional GET, GRAB or HEAD to depUri with depUri*/serCacheLM
# my $ua = LWP::UserAgent->new;
my $ua = WWW::Mechanize->new();
$ua->agent("$0/0.01 " . $ua->agent);
my $requestUri = $depUri;
my $httpMethod = $method;
if ($method eq "GRAB") {
	$httpMethod = "GET";
	$requestUri .= "?method=$method";
	}
elsif ($method eq "NOTIFY") {
	$httpMethod = "HEAD";
	$requestUri .= "?method=$method";
	}
# Set If-Modified-Since and If-None-Match headers in request, if available.
my $inSerName = $nm->{hash}->{$thisUri}->{dependsOnSerName}->{$depUri} || die;
my $inSerNameUri = $nm->{hash}->{$thisUri}->{dependsOnSerNameUri}->{$depUri} || die;
my ($oldLM, $oldLMHeader, $oldETagHeader) = &LookupLMs($inSerNameUri);
$oldLM ||= "";
$oldLMHeader ||= "";
$oldETagHeader ||= "";
if ($depLM && $oldLM && $oldLM eq $depLM) {
	return $oldLM;
	}
my $req = HTTP::Request->new($httpMethod => $requestUri);
$req || die;
$req->header('If-Modified-Since' => $oldLMHeader) if $oldLMHeader;
$req->header('If-None-Match' => $oldETagHeader) if $oldETagHeader;
my $isConditional = $req->header('If-Modified-Since') ? "CONDITIONAL" : "";
my $reqString = $req->as_string;
&Warn("  ForeignSendHttpRequest: Sending remote $isConditional $method Request from $thisUri to $depUri with ETag $oldETagHeader\n", 2);
&PrintLog("[[\n$reqString\n]]\n");
############# Sending the HTTP request ##############
my $res = $ua->request($req) or die;
my $code = $res->code;
$code == RC_NOT_MODIFIED || $code == RC_OK or die "ERROR: Unexpected HTTP response code $code ";
&Warn("  ForeignSendHttpRequest: $isConditional $method Request from $thisUri to $depUri returned $code\n", 2);
my $newLMHeader = $res->header('Last-Modified') || "";
my $newETagHeader = $res->header('ETag') || "";
my $newLM = &HeadersToLM($newLMHeader, $newETagHeader);
if ($code == RC_OK && $newLM && $newLM ne $oldLM) {
	### Allow non-monotonic LM (because they could be checksums):
	### $newLM gt $oldLM || die; # Verify monotonic LM
	# Need to save the content to file $inSerName.
	# TODO: Figure out whether the content should be decoded first.  
	# If not, should the Content-Type and Content-Encoding headers 
	# be saved with the LM perhaps? Or is there a more efficient way 
	# to save the content to file $inSerName, such as using 
	# $ua->get($url, ':content_file'=>$filename) ?  See
	# http://search.cpan.org/~gaas/libwww-perl-6.03/lib/LWP/UserAgent.pm
	&MakeParentDirs( $inSerName );
	&Warn("UPDATING inSerName: $inSerName\n", 1); 
	$ua->save_content( $inSerName ) if $method ne 'HEAD';
	&SaveLMs($inSerNameUri, $newLM, $newLMHeader, $newETagHeader);
	}
return $newLM;
}

################### DeserializeToLocalCache ##################
# Update $thisUri's local cache of $depUri's out, by deserializing
# (if necessary) from $thisUri's local serCache of $depUri.
sub DeserializeToLocalCache
{
@_ == 4 or die;
my ($nm, $thisUri, $depUri, $depLM) = @_;
&Warn("DeserializeToLocalCache(nm, $thisUri, $depUri, $depLM) called\n", 2);
my $thisHHash = $nm->{hash}->{$thisUri} || {};
my $thisDepSerNameHash = $thisHHash->{dependsOnSerName} || {};
my $depSerName = $thisDepSerNameHash->{$depUri};
my $thisDepNameHash = $thisHHash->{dependsOnName} || {};
my $depName = $thisDepNameHash->{$depUri};
my $thisDepNameUriHash = $thisHHash->{dependsOnNameUri} || {};
my $depNameUri = $thisDepNameUriHash->{$depUri};
my $depVHash = $nm->{value}->{$depUri} || {};
my $depType = $depVHash->{nodeType} || "";
my $depTypeVHash = $nm->{value}->{$depType} || {};
my $fDeserializer = $depTypeVHash->{fDeserializer} || "";
return if !$fDeserializer;
my ($oldCacheLM) = &LookupLMs($depNameUri);
my $fExists = $depTypeVHash->{fExists} or die;
$oldCacheLM = "" if !&{$fExists}($depName);
return if (!$depLM || $depLM eq $oldCacheLM);
&Warn("UPDATING local cache: $depName\n", 1); 
&{$fDeserializer}($depSerName, $depName);
&SaveLMs($depNameUri, $depLM);
}

################### HandleHttpEvent ##################
sub HandleHttpEvent
{
@_ == 2 or die;
my ($nm, $r) = @_;
# construct_url omits the query params
my $thisUri = $r->construct_url(); 
&Warn("HandleHttpEvent called: thisUri: $thisUri\n", 2);
my $thisVHash = $nm->{value}->{$thisUri} || {};
my $thisType = $thisVHash->{nodeType} || "";
if (!$thisType) {
	&Warn("INTERNAL ERROR: HandleHttpEvent called, but $thisUri has no nodeType.\n");
	return Apache2::Const::SERVER_ERROR;
	}
my $args = $r->args() || "";
&Warn("  Query string: $args\n", 2);
my %args = &ParseQueryString($args);
my $callerUri = $args{callerUri} || "";
my $callerLM = $args{callerLM} || "";
my $method = $args{method} || $r->method;
return Apache2::Const::HTTP_METHOD_NOT_ALLOWED 
  if $method ne "HEAD" && $method ne "GET" && $method ne "GRAB" 
	&& $method ne "NOTIFY";
# TODO: If $r has fresh content, then store it.
&Warn("  HandleHttpEvent method: $method callerUri: $callerUri callerLM: $callerLM\n", 2);
my $newThisLM = &FreshenSerOut($nm, $method, $thisUri, $callerUri, $callerLM);
####### Ready to generate the HTTP response. ########
my $serOut = $thisVHash->{serOut} || die;
my $serOutUri = $thisVHash->{serOutUri} || die;
my $size = -s $serOut || 0;
$r->set_content_length($size);
# TODO: Should use Accept header in choosing contentType.
my $contentType = $thisVHash->{contentType}
	|| $nm->{value}->{$thisType}->{defaultContentType}
	|| "text/plain";
# These work:
# $r->content_type('text/plain');
# $r->content_type('application/rdf+xml');
$r->content_type($contentType);
$r->headers_out->set('Content-Location' => $serOutUri); 
my ($lmHeader, $eTagHeader) = &LMToHeaders($newThisLM);
# These work:
# "W/" prefix on ETag means that it is weak.
# $r->headers_out->set('ETag' => 'W/"640e9-a-4b269027adb7d;4b142a708a8ad"'); 
# $r->headers_out->set('ETag' => 'W/"fake-etag"'); 
# Don't use this method, because $lmHeader is already formatted:
# $r->set_last_modified($mtime);
$r->headers_out->set('Last-Modified' => $lmHeader) if $lmHeader; 
$r->headers_out->set('ETag' => $eTagHeader) if $eTagHeader; 
# Done setting headers.  Determine status code to return, and
# send content body if 200 and not HEAD.
my $status = $r->meets_conditions();
if($status != Apache2::Const::OK || $r->header_only) {
  # $r->status(Apache2::Const::HTTP_NOT_MODIFIED);
  # Also returns 304 if appropriate:
  return $status;
  }
# sendfile seems to want a full file system path:
$r->sendfile($serOut);
return Apache2::Const::OK;
}

################### FreshenSerOut ##################
sub FreshenSerOut
{
@_ == 5 or die;
my ($nm, $method, $thisUri, $callerUri, $callerLM) = @_;
&Warn("FreshenSerOut(nm, $method, $thisUri, $callerUri, $callerLM) called\n", 2);
my $thisVHash = $nm->{value}->{$thisUri} || die;
my $thisType = $thisVHash->{nodeType} || die;
my $out = $thisVHash->{out} || die;
my $serOut = $thisVHash->{serOut} || die;
my $outUri = $thisVHash->{outUri} || die;
my $serOutUri = $thisVHash->{serOutUri} || die;
my $newThisLM = &FreshenOut($nm, 'GET', $thisUri, $callerUri, $callerLM);
&Warn("  FreshenOut $thisUri returned newThisLM: $newThisLM\n", 2);
if ($method eq 'HEAD' || $method eq 'NOTIFY' || $outUri eq $serOutUri) {
  &Warn("  FreshenSerOut: No serialization needed. Returning newThisLM: $newThisLM\n", 2);
  return $newThisLM;
  }
# Need to update serOut?
my ($serOutLM) = &LookupLMs($serOutUri);
if (!$serOutLM || !-e $serOut || ($newThisLM && $newThisLM ne $serOutLM)) {
  ### Allow non-monotonic LM (because they could be checksums):
  ### die if $newThisLM && $serOutLM && $newThisLM lt $serOutLM;
  # TODO: Set $acceptHeader from $r, and use it to choose $contentType:
  # This could be done by making {fSerialize} a hash from $contentType
  # to the serialization function.
  # my $acceptHeader = $r->headers_in->get('Accept') || "";
  # warn "acceptHeader: $acceptHeader\n";
  my $fSerialize = $thisVHash->{fSerialize} || die;
  &Warn("UPDATING serOut: $serOut\n", 1); 
  &{$fSerialize}($out, $serOut) or die;
  $serOutLM = $newThisLM;
  &SaveLMs($serOutUri, $serOutLM);
  }
&Warn("  FreshenSerOut: Returning serOutLM: $serOutLM\n", 2);
return $serOutLM
}

################### FreshenOut ################### 
# $callerUri and $callerLM are only used if $method is NOTIFY
sub FreshenOut
{
@_ == 5 or die;
my ($nm, $method, $thisUri, $callerUri, $callerLM) = @_;
&Warn("FreshenOut(nm, $method, $thisUri, $callerUri, $callerLM) called\n", 2);
my ($oldThisLM, %oldDepLMs) = &LookupLMs($thisUri);
return $oldThisLM if $method eq "GRAB";
my $thisVHash = $nm->{value}->{$thisUri};
my $thisLHash = $nm->{list}->{$thisUri};
my $thisType = $thisVHash->{nodeType} or die;
# Run thisUri's update policy for this event:
my $fUpdatePolicy = $thisVHash->{fUpdatePolicy} or die;
my $policySaysFreshen = 
	&{$fUpdatePolicy}($nm, $method, $thisUri, $callerUri, $callerLM);
return $oldThisLM if !$policySaysFreshen;
my ($thisIsStale, $newDepLMs) = 
	&RequestLatestDependsOns($nm, $thisUri, $callerUri, $callerLM, \%oldDepLMs);
my $out = $thisVHash->{out} or die;
my $fOutExists = $nm->{value}->{$thisType}->{fOutExists} or die;
$oldThisLM = "" if !&{$fOutExists}($out);
$thisIsStale = 1 if !$oldThisLM;
my $thisUpdater = $thisVHash->{updater} || "";
return $oldThisLM if $thisUpdater && !$thisIsStale;
my $thisInputs = $thisLHash->{inputNames} || [];
my $thisParameters = $thisLHash->{inputParameters} || [];
# TODO: Figure out what to do if a node is STUCK, i.e., inputs
# have changed but there is no updater.
die "ERROR: Node $thisUri is STUCK: Inputs but no updater. " 
	if @{$thisInputs} && !$thisUpdater;
my $fRunUpdater = $nm->{value}->{$thisType}->{fRunUpdater} or die;
# If there is no updater then it is up to $fRunUpdater to generate
# an LM for the static out.
&Warn("UPDATING $thisUri {$thisUpdater} out: $out\n", 1); 
my $newThisLM = &{$fRunUpdater}($nm, $thisUri, $thisUpdater, $out, 
	$thisInputs, $thisParameters, $oldThisLM, $callerUri, $callerLM);
&Warn("WARNING: fRunUpdater on $thisUri $thisUpdater returned false LM") if !$newThisLM;
&SaveLMs($thisUri, $newThisLM, %{$newDepLMs});
return $newThisLM if $newThisLM eq $oldThisLM;
### Allow non-monotonic LM (because they could be checksums):
### $newThisLM gt $oldThisLM or die;
# Notify outputs of change:
my @outputs = sort keys %{$thisVHash->{outputs}};
foreach my $outUri (@outputs) {
	next if $outUri eq $callerUri;
	&Notify($nm, $outUri, $thisUri, $newThisLM);
	}
return $newThisLM;
}

################### Notify ################### 
sub Notify
{
@_ == 4 or die;
my ($nm, $thisUri, $callerUri, $callerLM) = @_;
&Warn("Notify(nm, $thisUri, $callerUri, $callerLM) called\n", 2);
# Avoid unused var warning:
($nm, $thisUri, $callerUri, $callerLM) = 
($nm, $thisUri, $callerUri, $callerLM);
# TODO: Queue a NOTIFY event.
}

################### RequestLatestDependsOns ################### 
# Logic table for each $depUri:
#       is      known   is      same    same
#       Input   Fresh   Node    Server  Type    Action
#       0       0       0       x       x       Foreign HEAD
#       0       0       1       0       x       Foreign HEAD
#       0       0       1       1       0       Neighbor HEAD
#       0       0       1       1       1       Local HEAD/GET*
#       0       1       x       x       x       Nothing to do
#       1       0       0       x       x       Foreign GET
#       1       0       1       0       x       Foreign GET
#       1       0       1       1       0       Neighbor GET
#       1       0       1       1       1       Local GET
#       1       1       0       x       x       Foreign GET/GRAB**
#       1       1       1       0       x       Foreign GRAB
#       1       1       1       1       0       Neighbor GRAB
#       1       1       1       1       1       Nothing to do
#  * No difference between HEAD and GET for local node.
#  ** No difference between GET and GRAB for non-node.
sub RequestLatestDependsOns
{
@_ == 5 or die;
my ($nm, $thisUri, $callerUri, $callerLM, $oldDepLMs) = @_;
&Warn("RequestLatestDependsOn(nm, $thisUri, $callerUri, $callerLM, $oldDepLMs) called\n", 2);
# callerUri and callerLM are only used to avoid requesting the latest 
# state from an input/parameter that is already known fresh, because 
# it was the one that notified thisUri.
# Thus, they are not used when this was called because of a GET.
my $thisVHash = $nm->{value}->{$thisUri};
my $thisHHash = $nm->{hash}->{$thisUri};
my $thisType = $thisVHash->{nodeType};
my $thisIsStale = 0;
my $thisDependsOn = $thisHHash->{dependsOn};
my $newDepLMs = {};
foreach my $depUri (sort keys %{$thisDependsOn}) {
  # Bear in mind that a node may dependsOn a non-node arbitrary http 
  # or file:// source, so $depVHash may be undef.
  my $depVHash = $nm->{value}->{$depUri} || {};
  my $depType = $depVHash->{nodeType} || "";
  my $newDepLM;
  my $method = 'GET';
  my $depLM = "";
  my $isInput = $thisHHash->{inputs}->{$depUri} 
	|| $thisHHash->{parameters}->{$depUri} || 0;
  # TODO: Future optimization: if depUri is in %knownFresh ...
  my $knownFresh = ($depUri eq $callerUri) && $callerLM && 1;
  $knownFresh ||= 0;	# Nicer for logs if false.
  if ($knownFresh) {
    $method = 'GRAB';
    $depLM = $callerLM;
    }
  elsif (!$isInput) {
    $method = 'HEAD';
    }
  my $isSameServer = &IsSameServer($thisUri, $depUri) || 0;
  my $isSameType   = &IsSameType($thisType, $depType) || 0;
  if (0 && $thisUri eq "http://localhost/odds" && $depUri eq "http://localhost/max") {
	&Warn("REMOVE AFTER TESTING!!!\n");
	$isSameType = 1;
	}
  &Warn("  depUri: $depUri depType: $depType method: $method depLM: $depLM\n    isSameServer: $isSameServer isSameType: $isSameType knownFresh: $knownFresh isInput: $isInput\n", 2);
  if ($knownFresh && !$isInput) {
    # Nothing to do, because we don't need $depUri's content.
    $newDepLM = $callerLM;
    &Warn("  Nothing to do: Caller known fresh and not an input/parameter.\n", 2);
    }
  elsif (!$depType || !$isSameServer) {
    # Foreign node or non-node.
    $newDepLM = &ForeignSendHttpRequest($nm, $method, $thisUri, $depUri, $depLM);
    &DeserializeToLocalCache($nm, $thisUri, $depUri, $newDepLM);
    }
  elsif (!$isSameType) {
    # Neighbor: Same server but different type.
    $newDepLM = &FreshenSerOut($nm, $method, $thisUri, $callerUri, $callerLM);
    &DeserializeToLocalCache($nm, $thisUri, $depUri, $newDepLM);
    }
  elsif ($knownFresh) {
    # Nothing to do, because it's local and already known fresh.
    $newDepLM = $callerLM;
    &Warn("  Nothing to do: Caller known fresh and local.\n", 2);
    }
  else {
    # Local: Same server and type, but not known fresh.  When local, GET==HEAD.
    # &Warn("  Same server and type.\n", 2);
    $newDepLM = &FreshenOut($nm, 'GET', $depUri, "", "");
    &Warn("  FreshenOut $thisUri returned newDepLM: $newDepLM\n", 2);
    }
  my $oldDepLM = $oldDepLMs->{$depUri} || "";
  $thisIsStale = 1 if !$oldDepLM || ($newDepLM && $newDepLM ne $oldDepLM);
  $newDepLMs->{$depUri} = $newDepLM;
  }
&Warn("RequestLatestDependsOn(nm, $thisUri, $callerUri, $callerLM, $oldDepLMs) returning: $thisIsStale\n", 2);
return( $thisIsStale, $newDepLMs )
}

################### LoadNodeMetadata #################
sub LoadNodeMetadata
{
@_ == 3 or die;
my ($nm, $ontFile, $configFile) = @_;
my %config = &CheatLoadN3($ontFile, $configFile);
my $nmv = $nm->{value};
my $nml = $nm->{list};
my $nmh = $nm->{hash};
foreach my $k (sort keys %config) {
	# &Warn("  LoadNodeMetadata key: $k\n", 2);
	my ($s, $p) = split(/\s+/, $k) or die;
	my $v = $config{$k};
	die if !defined($v);
	my @vList = split(/\s+/, $v); 
	my %vHash = map { ($_, 1) } @vList;
	$nmv->{$s}->{$p} = $v;
	$nml->{$s}->{$p} = \@vList;
	$nmh->{$s}->{$p} = \%vHash;
	# &Warn("  $s -> $p -> $v\n", 2);
	}
&PresetGenericDefaults($nm);
# Run the initialization function to set defaults for each node type 
# (i.e., wrapper type), starting with leaf nodes and working up the hierarchy.
my @leaves = &LeafClasses($nm, keys %{$nmh->{Node}->{subClass}});
my %done = ();
while(@leaves) {
	my $nodeType = shift @leaves;
	next if $done{$nodeType};
	$done{$nodeType} = 1;
	my @superClasses = keys %{$nmh->{$nodeType}->{$subClassOf}};
	push(@leaves, @superClasses);
	my $fSetNodeDefaults = $nmv->{$nodeType}->{fSetNodeDefaults};
	next if !$fSetNodeDefaults;
	&{$fSetNodeDefaults}($nm);
	}
return $nm;
}

################### PresetGenericDefaults #################
# Preset essential generic $nmv, $nml, $nmh defaults that must be set
# before nodeType-specific defaults are set.  In particular, the
# following are set for every node: nodeType.  Plus the following
# are set for every node on this server:
# outOriginal, out, outUri, serOut, serOutUri, stderr.
sub PresetGenericDefaults
{
@_ == 1 or die;
my ($nm) = @_;
my $nmv = $nm->{value};
my $nml = $nm->{list};
my $nmh = $nm->{hash};
# &Warn("PresetGenericDefaults:\n");
# First set defaults that are set directly on each node: 
# nodeType, out, outUri, serOut, serOutUri, stderr, fUpdatePolicy.
foreach my $thisUri (keys %{$nmh->{Node}->{member}}) 
  {
  # Make life easier in this loop:
  my $thisVHash = $nmv->{$thisUri} or die;
  my $thisLHash = $nml->{$thisUri} or die;
  my $thisHHash = $nmh->{$thisUri} or die;
  # Set nodeType, which should be most specific node type.
  my @types = keys %{$thisHHash->{a}};
  my @nodeTypes = LeafClasses($nm, @types);
  die if @nodeTypes > 1;
  die if @nodeTypes < 1;
  my $thisType = $nodeTypes[0];
  $thisVHash->{nodeType} = $thisType;
  # Nothing more to do if $thisUri is not hosted on this server:
  next if !&IsSameServer($baseUri, $thisUri);
  # Save original out before setting it to a default value:
  $thisVHash->{outOriginal} = $thisVHash->{out};
  # Set out, outUri, serOut and serOutUri if not set.  
  # out is a local name; serOut is a file path.
  my $thisFUriToLocalName = $nmv->{$thisType}->{fUriToLocalName} || "";
  my $defaultOutUri = "$baseUri/cache/" . &QuickName($thisUri) . "/out";
  my $defaultOut = $defaultOutUri;
  $defaultOut = &{$thisFUriToLocalName}($defaultOut) 
	if $thisFUriToLocalName;
  my $thisName = $thisFUriToLocalName ? &{$thisFUriToLocalName}($thisUri) : $thisUri;
  $thisVHash->{out} ||= 
    $thisVHash->{updater} ? $defaultOut : $thisName;
  $thisVHash->{outUri} ||= 
    $thisVHash->{updater} ? $defaultOutUri : $thisUri;
  $thisVHash->{serOut} ||= 
    $nmv->{$thisType}->{fSerializer} ?
      "$basePath/cache/" . &QuickName($thisUri) . "/serOut"
      : $thisVHash->{out};
  $thisVHash->{serOutUri} ||= &PathToUri($thisVHash->{serOut});
  # For capturing stderr:
  $nmv->{$thisUri}->{stderr} ||= 
	  "$basePath/cache/" . &QuickName($thisUri) . "/stderr";
  $thisVHash->{fUpdatePolicy} ||= \&LazyUpdatePolicy;
  # Simplify later code:
  &MakeValuesAbsoluteUris($nmv, $nml, $nmh, $thisUri, "inputs");
  &MakeValuesAbsoluteUris($nmv, $nml, $nmh, $thisUri, "parameters");
  &MakeValuesAbsoluteUris($nmv, $nml, $nmh, $thisUri, "dependsOn");
  &Warn("WARNING: Node $thisUri has inputs but no updater ")
	if !$thisVHash->{updater} && @{$thisLHash->{inputs}};
  # Initialize the list of outputs (actually inverse dependsOn) for each node:
  $nmh->{$thisUri}->{outputs} = {};
  }

# Now go through each node again, setting values related to each
# node's dependsOns, which may make use of properties that were
# set in the previous loop.
foreach my $thisUri (keys %{$nmh->{Node}->{member}}) 
  {
  # Nothing to do if $thisUri is not hosted on this server:
  next if !&IsSameServer($baseUri, $thisUri);
  # Make life easier in this loop:
  my $thisVHash = $nmv->{$thisUri};
  my $thisLHash = $nml->{$thisUri};
  my $thisHHash = $nmh->{$thisUri};
  my $thisType = $thisVHash->{nodeType};
  # The dependsOnName hash is used for inputs from other environments
  # and maps from dependsOn URIs (or inputs/parameter URIs) to the local names 
  # that will be used by $thisUri's updater when
  # it is invoked.  It will either use a new name (if the input is from
  # a different environment) or the input's out directly (if in the 
  # same env).  A non-node dependsOn is treated like a foreign
  # node with no serializer.  
  # The dependsOnSerName hash similarly maps
  # from dependsOn URIs to the local serNames (i.e., file names of 
  # inputs) that will be used to refresh the local cache if the
  # input is foreign.  However, since different node types within
  # the same server can share the serialized inputs, then 
  # the dependsOnSerName may be set using the input's serOut.
  # The dependsOnNameUri and dependsOnSerNameUri hashes are URIs corresponding
  # to dependsOnName and dependsOnSerName, and are used as keys for LMs.
  # Factors that affect these settings:
  #  A. Is $depUri a node?  It may be any other URI data source (http: or file:).
  #  B. Is $depUri on the same server (as $thisUri)?
  #     If so, its serCache can be shared with other nodes on this server.
  #  C. Is $depType the same node type $thisType?
  #     If so (and on same server) then the node's out can be accessed directly.
  #  D. Does $depType have a deserializer?
  #     If not, then 'cache' will be the same as serCache.
  #  E. Does $depType have a fUriToLocalName function?
  #     If so, then it will be used to generate a local name for 'cache'.
  $thisHHash->{dependsOnName} ||= {};
  $thisHHash->{dependsOnSerName} ||= {};
  $thisHHash->{dependsOnNameUri} ||= {};
  $thisHHash->{dependsOnSerNameUri} ||= {};
  foreach my $depUri (keys %{$thisHHash->{dependsOn}}) {
    # Ensure non-null hashrefs for all ins (because they may not be nodes):
    $nmv->{$depUri} = {} if !$nmv->{$depUri};
    $nml->{$depUri} = {} if !$nml->{$depUri};
    $nmh->{$depUri} = {} if !$nmh->{$depUri};
    # my $depUriEncoded = uri_escape($depUri);
    my $depUriEncoded = &QuickName($depUri);
    # $depType will be false if $depUri is not a node:
    my $depType = $nmv->{$depUri}->{nodeType} || "";
    # First set dependsOnSerName and dependsOnSerNameUri.
    if ($depType && &IsSameServer($baseUri, $depUri)) {
      # Same server, so re-use the input's serOut.
      $thisHHash->{dependsOnSerName}->{$depUri} = $nmv->{$depUri}->{serOut};
      }
    else {
      # Different servers, so make up a new file path.
      # dependsOnSerName file path does not need to contain $thisType, because 
      # different node types on the same server can share the same serCache's.
      my $depSerName = "$basePath/cache/$depUriEncoded/serCache";
      $thisHHash->{dependsOnSerName}->{$depUri} = $depSerName;
      }
    $thisHHash->{dependsOnSerNameUri}->{$depUri} ||= 
	      &PathToUri($thisHHash->{dependsOnSerName}->{$depUri}) || die;
    # Now set dependsOnName and dependsOnNameUri.
    my $fDeserializer = $depType ? $nmv->{$depType}->{fDeserializer} : "";
    if (&IsSameServer($baseUri, $depUri) && &IsSameType($thisType, $depType)) {
      # Same env.  Reuse the input's out.
      $thisHHash->{dependsOnName}->{$depUri} = $nmv->{$depUri}->{out};
      $thisHHash->{dependsOnNameUri}->{$depUri} = $nmv->{$depUri}->{outUri};
      # warn "thisUri: $thisUri depUri: $depUri Path 1\n";
      }
    elsif ($fDeserializer) {
      # There is a deserializer, so we must create a new {cache} name.
      # Create a URI and convert it
      # (if necessary) to an appropriate local name.
      my $fUriToLocalName = $nmv->{$depType}->{fUriToLocalName};
      my $cacheName = "$baseUri/cache/$thisType/$depUriEncoded/cache";
      $thisHHash->{dependsOnNameUri}->{$depUri} = $cacheName;
      $cacheName = &{$fUriToLocalName}($cacheName) if $fUriToLocalName;
      $thisHHash->{dependsOnName}->{$depUri} = $cacheName;
      # warn "thisUri: $thisUri depUri: $depUri Path 2\n";
      }
    else {
      # No deserializer, so dependsOnName will be the same as dependsOnSerName.
      my $path = $thisHHash->{dependsOnSerName}->{$depUri};
      $thisHHash->{dependsOnName}->{$depUri} = $path;
      $thisHHash->{dependsOnNameUri}->{$depUri} = &PathToUri($path);
      # warn "thisUri: $thisUri depUri: $depUri Path 3\n";
      }
    # my $don = $thisHHash->{dependsOnName}->{$depUri};
    # my $dosn = $thisHHash->{dependsOnSerName}->{$depUri};
    # my $donu = $thisHHash->{dependsOnNameUri}->{$depUri};
    # my $dosnu = $thisHHash->{dependsOnSerNameUri}->{$depUri};
    # warn "thisUri: $thisUri depUri: $depUri $depType $don $dosn $donu $dosnu\n";
    #
    # Set the list of outputs (actually inverse dependsOn) for each node:
    $nmh->{$depUri}->{outputs}->{$thisUri} = 1 if $depType;
    }
  # Set the list of input local names for this node.
  $thisLHash->{inputNames} ||= [];
  foreach my $inUri (@{$thisLHash->{inputs}}) {
    my $inName = $thisHHash->{dependsOnName}->{$inUri};
    push(@{$thisLHash->{inputNames}}, $inName);
    }
  # Set the list of parameter local names for this node.
  $thisLHash->{parameterNames} ||= [];
  foreach my $pUri (@{$thisLHash->{parameters}}) {
    my $pName = $thisHHash->{dependsOnName}->{$pUri};
    push(@{$thisLHash->{parameterNames}}, $pName);
    }
  }
}

################# MakeValuesAbsoluteUris ####################
sub MakeValuesAbsoluteUris 
{
@_ == 5 or die;
my ($nmv, $nml, $nmh, $thisUri, $predicate) = @_;
my $oldV = $nmv->{$thisUri}->{$predicate} || "";
my $oldL = $nml->{$thisUri}->{$predicate} || [];
my $oldH = $nmh->{$thisUri}->{$predicate} || {};
# In the case of a hash, it is the key that is made absolute:
my %hash = map {(&NodeAbsUri($_), $oldH->{$_})} keys %{$oldH};
my @list = map {&NodeAbsUri($_)} @{$oldL};
my $value = join(" ", @list);
$nmv->{$thisUri}->{$predicate} = $value;
$nml->{$thisUri}->{$predicate} = \@list;
$nmh->{$thisUri}->{$predicate} = \%hash;
return;
}

################### LazyUpdatePolicy ################### 
# Return 1 iff $thisUri should be freshened according to lazy update policy.
# $method is one of qw(GET HEAD NOTIFY). It is never GRAB, because there
# is never any updating involved with GRAB.
sub LazyUpdatePolicy
{
@_ == 5 or die;
my ($nm, $method, $thisUri, $callerUri, $callerLM) = @_;
# Avoid unused var warning:
($nm, $method, $thisUri, $callerUri, $callerLM) = 
($nm, $method, $thisUri, $callerUri, $callerLM);
return 1 if $method eq "GET";
return 1 if $method eq "HEAD";
return 0 if $method eq "NOTIFY";
die;
}

################### LeafClasses #################
# Given a list of classes (with rdfs:subClassOf relations in $nmv, $nml, $nmh), 
# return the ones that are not a 
# superclass of any of them.  The list of classes is expected to
# be complete, e.g., for if you have:
#	:a rdfs:subClassOf :b .
#	:b rdfs:subClassOf :c .
# then if :a is in the given list of classes then :b (and :c) must be also.
sub LeafClasses
{
@_ >= 1 or die;
my ($nm, @classes) = @_;
my $nmh = $nm->{hash};
my @leaves = ();
# Simple n-squared algorithm should be okay for small numbers of classes:
foreach my $t (@classes) {
	my $isSuperclass = 0;
	foreach my $subType (@classes) {
		next if $t eq $subType;
		next if !$nmh->{$subType};
		next if !$nmh->{$subType}->{$subClassOf};
		next if !$nmh->{$subType}->{$subClassOf}->{$t};
		$isSuperclass = 1;
		last;
		}
	push(@leaves, $t) if !$isSuperclass;
	}
return @leaves;
}

################### BuildQueryString #################
# Given a hash of key/value pairs, escape both keys and values and
# put them into a query string (not including the "?"), which is returned.
sub BuildQueryString
{
my %args = @_;
my $args = join("&", 
	map { uri_escape($_) . "=" . uri_escape($args{$_}) }
	keys %args);
return $args;
}

################### ParseQueryString #################
# Returns a hash of key/value pairs, with both keys and values unescaped.
# If the same key appears more than once in the query string,
# the last value given wins.
# TODO: Not sure this function is needed.  Maybe $r->param can be used
# instead?  See:
# https://metacpan.org/module/Apache2::Request#param
sub ParseQueryString
{
my $args = shift || "";
my %args = map { 
	my ($k,$v) = split(/\=/, $_); 
	$v = "" if !defined($v); 
	$k ? (uri_unescaped($k), uri_unescape($v)) : ()
	} split(/\&/, $args);
return %args;
}

################### CheatLoadN3 #####################
# Not proper n3 parsing, but good enough for this purpose.
# Returns a hash map that maps: "$s $p" --> $o
# Global $prefix is also stripped off from terms.
# Example: "http://localhost/a out" --> "c/cp-out.txt"
sub CheatLoadN3
{
my $ontFile = shift;
my $configFile = shift;
$configFile || die;
-e $configFile || die;
my $cwmCmd = "cwm --n3=ps $ontFile $internalsFile $configFile --think |";
&PrintLog("cwmCmd: $cwmCmd\n");
open(my $fh, $cwmCmd) || die;
my $nc = " " . join(" ", map { chomp; 
	s/^\s*\#.*//; 		# Strip full line comments
	s/\.(\W)/ .$1/g; 	# Add space before period except in a word
	$_ } <$fh>) . " ";
close($fh);
# &PrintLog("-" x 60 . "\n") if $debug;
# &PrintLog("nc: $nc\n") if $debug;
# &PrintLog("-" x 60 . "\n") if $debug;
while ($nc =~ s/\{[^\}]*\}/ /) {}	# Delete subgraphs: { ... } 
my @triples = grep { m/\S/ } 
	map { s/[()\"]/ /g; 		# Strip: ( ) "
		s/<([^<>\s]+)>/$1/g; 	# Strip < > but Keep empty <>
		s/\A\s+//; s/\s+\Z//; 
		s/\A\s*\@.*//; s/\s\s+/ /g; $_ } 
	split(/\s+\./, $nc);
my $nTriples = scalar @triples;
&PrintLog("nTriples: $nTriples\n") if $debug;
# &PrintLog("-" x 60 . "\n") if $debug;
# &PrintLog("triples: \n" . join("\n", @triples) . "\n") if $debug;
&PrintLog("-" x 60 . "\n") if $debug;
my %config = ();
foreach my $t (@triples) {
	# Strip ont prefix from terms:
	$t = join(" ", map { s/\A$prefix([a-zA-Z])/$1/;	$_ }
		split(/\s+/, $t));
	# Convert rdfs: namespace to "rdfs:" prefix:
	$t = join(" ", map { s/\A$rdfsPrefix([a-zA-Z])/rdfs:$1/;	$_ }
		split(/\s+/, $t));
	my ($s, $p, $o) = split(/\s+/, $t, 3);
	next if !$o;
	# $o may actually be a space-separate list of URIs
	# &PrintLog("  s: $s p: $p o: $o\n") if $debug;
	# Append additional values for the same property:
	$config{"$s $p"} = "" if !exists($config{"$s $p"});
	$config{"$s $p"} .= " " if $config{"$s $p"};
	$config{"$s $p"} .= $o;
	}
&PrintLog("-" x 60 . "\n") if $debug;
return %config;
}

############ WriteFile ##########
# Write a file.  Examples:
#   &WriteFile("/tmp/foo", $all)   # Same as &WriteFile(">/tmp/foo", all);
#   &WriteFile(">$f", $all)
#   &WriteFile(">>$f", $all)
# Parent directories are automatically created as needed.
sub WriteFile
{
@_ == 2 || die;
my ($f, $all) = @_;
my $ff = (($f =~ m/\A\>/) ? $f : ">$f");    # Default to ">$f"
my $nameOnly = $ff;
$nameOnly =~ s/\A\>(\>?)//;
&MakeParentDirs($nameOnly);
open(my $fh, $ff) || die;
print $fh $all;
close($fh) || die;
}

############ ReadFile ##########
# Read a file and return its contents or "" if the file does not exist.  
# Examples:
#   my $all = &ReadFile("<$f")
sub ReadFile
{
@_ == 1 || die;
my ($f) = @_;
open(my $fh, $f) || return "";
my $all = join("", <$fh>);
close($fh) || die;
return $all;
}

############# UriToLmFile #############
# Convert $thisUri to a LM file path.
sub UriToLmFile
{
my $thisUri = shift;
my $lmFile = $UriToLmFile::lmFile{$thisUri};
if (!$lmFile) {
	$lmFile = &UriToPath($thisUri);
	### Commented out the true branch of this "if", to
	### put them all in $basePath/lm/
	if (0 && $lmFile && $lmFile =~ m|\A$basePathPattern\/cache\/|) {
		$lmFile .= "LM";
		}
	else	{
		my $t = uri_escape($thisUri);
		$lmFile = "$basePath/lm/$t";
		}
	$UriToLmFile::lmFile{$thisUri} = $lmFile;
	}
return $lmFile;
}

############# SaveLMs ##############
# Save Last-Modified times of $thisUri and its inputs (actually its dependsOns).
# Called as: &SaveLMs($thisUri, $thisLM, %depLMs);
sub SaveLMs
{
@_ >= 2 || die;
my ($thisUri, $thisLM, @depLMs) = @_;
my $f = &UriToLmFile($thisUri);
my $s = join("\n", "# $thisUri", $thisLM, @depLMs) . "\n";
&Warn("  SaveLMs($thisUri, $s) to file: $f\n", 2);
&WriteFile($f, $s);
}

############# LookupLMs ##############
# Lookup LM times of $thisUri and its inputs (actually its dependsOns).
# Called as: my ($thisLM, %depLMs) = &LookupLMs($thisUri);
sub LookupLMs
{
@_ == 1 || die;
my ($thisUri) = @_;
my $f = &UriToLmFile($thisUri);
open(my $fh, $f) or return ("", ());
my ($cThisUri, $thisLM, @depLMs) = map {chomp; $_} <$fh>;
close($fh) || die;
return($thisLM, @depLMs);
}

############# FileExists ##############
sub FileExists
{
@_ == 1 || die;
my ($f) = @_;
return -e $f;
}

############# RegisterWrappers ##############
sub RegisterWrappers
{
@_ == 1 || die;
my ($nm) = @_;
&FileNodeRegister($nm);
}

############# FileNodeRegister ##############
sub FileNodeRegister
{
@_ == 1 || die;
my ($nm) = @_;
$nm->{value}->{FileNode} = {};
$nm->{value}->{FileNode}->{fSerializer} = "";
$nm->{value}->{FileNode}->{fDeserializer} = "";
$nm->{value}->{FileNode}->{fUriToLocalName} = \&UriToPath;
$nm->{value}->{FileNode}->{fRunUpdater} = \&FileNodeRunUpdater;
$nm->{value}->{FileNode}->{fOutExists} = \&FileExists;
}

############# FileNodeRunUpdater ##############
# Run the updater.
# If there is no updater (i.e., static out) then we must generate
# an LM from the out.
sub FileNodeRunUpdater
{
@_ == 9 || die;
my ($nm, $thisUri, $updater, $out, $thisInputs, $thisParameters, 
	$oldThisLM, $callerUri, $callerLM) = @_;
# Avoid unused var warning:
($nm, $thisUri, $updater, $out, $thisInputs, $thisParameters, 
	$oldThisLM, $callerUri, $callerLM) = @_;
($nm, $thisUri, $updater, $out, $thisInputs, $thisParameters, 
	$oldThisLM, $callerUri, $callerLM) = @_;
&Warn("  FileNodeRunUpdater(nm, $thisUri, $updater, $out, ...) called.\n", 2);
$updater = &NodeAbsPath($updater) if $updater;
return &TimeToLM(&MTime($out)) if !$updater;
# TODO: Move this warning to when the metadata is loaded?
if (!-x $updater) {
	die "ERROR: $thisUri updater $updater is not executable by web server!";
	}
# The FileNode updater args are local filenames for all
# inputs and parameters.
my $inputFiles = join(" ", map {quotemeta($_)} 
	@{$nm->{list}->{$thisUri}->{inputNames}});
&Warn("    inputFiles: $inputFiles\n", 2);
my $parameterFiles = join(" ", map {quotemeta($_)} 
	@{$nm->{list}->{$thisUri}->{parameterNames}});
&Warn("    parameterFiles: $parameterFiles\n", 2);
my $ipFiles = "$inputFiles $parameterFiles";
my $stderr = $nm->{value}->{$thisUri}->{stderr};
# Make sure parent dirs exist for $stderr and $out:
&MakeParentDirs($stderr, $out);
# Ensure no unsafe chars before invoking $cmd:
my $qThisUri = quotemeta($thisUri);
my $qOut = quotemeta($out);
my $qUpdater = quotemeta($updater);
my $qStderr = quotemeta($stderr);
my $useStdout = 0;
$useStdout = 1 if $updater && !$nm->{value}->{$thisUri}->{outOriginal};
my $cmd = "( export $THIS_URI=$qThisUri ; $qUpdater $qOut $ipFiles > $qStderr 2>&1 )";
$cmd =    "( export $THIS_URI=$qThisUri ; $qUpdater         $ipFiles > $qOut 2> $qStderr )"
	if $useStdout;
&Warn("    cmd: $cmd\n", 2);
my $result = (system($cmd) >> 8);
my $saveError = $?;
&Warn("    FileNodeRunUpdater: Updater returned " . ($result ? "error code:" : "success:") . " $result.\n", 2);
if (-s $stderr) {
	&Warn("FileNodeRunUpdater: Updater stderr" . ($useStdout ? "" : " and stdout") . ":\n[[\n", 2);
	&Warn(&ReadFile("<$stderr"), 2);
	&Warn("]]\n", 2);
	}
# unlink $stderr;
if ($result) {
	&Warn("FileNodeRunUpdater: UPDATER ERROR: $saveError\n");
	return "";
	}
my $newLM = &GenerateNewLM();
&Warn("  FileNodeRunUpdater returning newLM: $newLM\n", 2);
return $newLM;
}

############# GenerateNewLM ##############
# Generate a new LM, based on the current time, that is guaranteed unique
# on this server even if this function is called faster than the 
# Time::HiRes clock resolution.  Furthermore, within the same thread
# it is guaranteed to increase monotonically (assuming the Time::HiRes
# clock increases monotonically).  This is done by
# appending a counter to the lower order digits of the current time.
# The counter is stored in $lmCounterFile and flock is used to
# ensure that it is accessed by only one thread at a time.
# As of 23-Jan-2012 on dbooth's laptop &GenerateNewLM() takes
# about 200-300 microseconds per call, so the counter will always 
# be 1 unless this is run on a machine that is much faster or that
# has substantially lower clock resolution.
#
# TODO: Need to test the locking (flock) aspect of this code.  The other 
# logic of this function has already been tested.
sub GenerateNewLM
{
# Format time to avoid losing digits when serializing:
my $newTime = &FormatTime(scalar(Time::HiRes::gettimeofday()));
my $MAGIC = "# Hi-Res Last Modified (LM) Counter\n";
&MakeParentDirs($lmCounterFile);
# Got this flock code pattern from
# http://www.stonehenge.com/merlyn/UnixReview/col23.html
# open(my $fh, "+<$lmCounterFile") or croak "Cannot open $lmCounterFile: $!";
sysopen(my $fh, $lmCounterFile, O_RDWR|O_CREAT) 
	or croak "Cannot open $lmCounterFile: $!";
flock $fh, 2;
my ($oldTime, $counter) = ($newTime, 0);
my $magic = <$fh>;
# Remember any warning, to avoid other I/O while $lmCounterFile is locked:
my $warning = "";	
if (defined($magic)) {
	$warning = "Corrupt lmCounter file (bad magic string): $lmCounterFile\n" if $magic ne $MAGIC;
	chomp( $oldTime = <$fh> );
	chomp( $counter = <$fh> );
	if (!$counter || !$oldTime || $oldTime>$newTime || $counter<=0) {
		$warning .= "Corrupt $lmCounterFile or non-monotonic clock\n";
		($oldTime, $counter) = ($newTime, 0);
		}
	}
$counter = 0 if $newTime > $oldTime;	# Reset counter whenever time changes
$counter++;
seek $fh, 0, 0;
truncate $fh, 0;
print $fh $MAGIC;
print $fh "$newTime\n";
print $fh "$counter\n";
close $fh;	# Release flock
&Warn("WARNING: $warning") if $warning;
return &TimeToLM($newTime, $counter);
}

############# MTime ##############
# Return the $mtime (modification time) of a file.
sub MTime
{
@_ == 1 || die;
my $f = shift;
my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
	      $atime,$mtime,$ctime,$blksize,$blocks)
		  = stat($f);
# Avoid unused var warning:
($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
	      $atime,$mtime,$ctime,$blksize,$blocks)
	= ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
	      $atime,$mtime,$ctime,$blksize,$blocks);
return $mtime;
}

############## QuickName ##############
# Generate a relative filename based on the given URI.
#### TODO:  This is a quick and dirty POC hack that makes the
#### filenames easier to read, for debugging purposes.  
#### Production code should url-encode the URI into the filename.
sub QuickName
{
my $t = shift;
# $t = uri_escape($t);
$t =~ s|\A.*\/||;	# Chop off all but the last part of the path
$t =~ s/[^a-zA-Z0-9\.\-\_]/_/g;	# Change any bad chars to _
return $t;
}

########## NodeAbsUri ############
# Converts (possibly relative) URI to absolute URI, using $nodeBaseUri.
sub NodeAbsUri
{
my $uri = shift;
##### TODO: Should this pattern be more general than just http:?
if ($uri !~ m/\Ahttp(s?)\:/) {
	# Relative URI
	$uri =~ s|\A\/||;	# Chop leading / if any
	$uri = "$nodeBaseUri/$uri";
	}
return $uri;
}

########## AbsUri ############
# Converts (possibly relative) URI to absolute URI, using $baseUri.
sub AbsUri
{
my $uri = shift;
##### TODO: Should this pattern be more general than just http:?
if ($uri !~ m/\Ahttp(s?)\:/) {
	# Relative URI
	$uri =~ s|\A\/||;	# Chop leading / if any
	$uri = "$baseUri/$uri";
	}
return $uri;
}

########## UriToPath ############
# Converts (possibly relative) URI to absolute file path (if local) 
# or returns "".
sub UriToPath
{
my $uri = shift;
my $path = &AbsUri($uri);
if ($path =~ s/\A$baseUriPattern\b/$basePath/e) {
	return $path;
	}
return "";
}

########## NodeAbsPath ############
# Converts (possibly relative) file path to absolute path,
# using $nodeBasePath.
sub NodeAbsPath
{
my $path = shift;
if ($path !~ m|\A\/|) {
	# Relative path
	$path = "$nodeBasePath/$path";
	}
return $path;
}

########## AbsPath ############
# Converts (possibly relative) file path to absolute path,
# using $basePath.
sub AbsPath
{
my $path = shift;
if ($path !~ m|\A\/|) {
	# Relative path
	$path = "$basePath/$path";
	}
return $path;
}

########## PathToUri ############
# Converts (possibly relative) file path to absolute URI (if local) 
# or returns "".
sub PathToUri
{
my $path = shift;
my $uri = &AbsPath($path);
if ($uri =~ s/\A$basePathPattern\b/$baseUri/e) {
	return $uri;
	}
return "";
}

########## PrintLog ############
sub PrintLog
{
open(my $fh, ">>$logFile") || die;
# print($fh, @_) or die;
print $fh @_ or die;
# print $fh @_;
close($fh) || die;
return 1;
}

########## Warn ############
# This will go to the apache error log: /var/log/apache2/error.log
sub Warn
{
die if @_ < 1 || @_ > 2;
my ($msg, $level) = @_;
&PrintLog($msg);
warn "debug not defined!\n" if !defined($debug);
warn "configLastModified not defined!\n" if !defined($configLastModified);
print STDERR $msg if !defined($level) || $debug >= $level;
return 1;
}

########## MakeParentDirs ############
# Ensure that parent directories exist before creating these files.
# Optionally, directories that have already been created are remembered, so
# we won't waste time trying to create them again.
sub MakeParentDirs
{
my $optionRemember = 0;
foreach my $f (@_) {
	next if $MakeParentDirs::fileSeen{$f} && $optionRemember;
	$MakeParentDirs::fileSeen{$f} = 1;
	my $fDir = "";
	$fDir = $1 if $f =~ m|\A(.*)\/|;
	next if $MakeParentDirs::dirSeen{$fDir} && $optionRemember;
	$MakeParentDirs::dirSeen{$fDir} = 1;
	next if $fDir eq "";	# Hit the root?
	make_path($fDir);
	-d $fDir || die;
	}
}

########## IsSameServer ############
# Is $thisUri on the same server as $baseUri?
sub IsSameServer
{
@_ == 2 or die;
my ($baseUri, $thisUri) = @_;
return 0 if !$baseUri or !$thisUri;
$baseUri =~ m/\A[^\/]*/;
my $baseServer = $& || "";
$thisUri =~ m/\A[^\/]*/;
my $thisServer = $& || "";
my $isSame = ($baseServer eq $thisServer);
# &Warn("IsSameServer($baseUri , $thisUri): $isSame\n", 2);
return $isSame;
}

########## IsSameType ############
# Are $thisType and $depType both set and the same?  
sub IsSameType
{
@_ == 2 or die;
my ($thisType, $depType) = @_;
my $isSame = $thisType && $depType && ($thisType eq $depType) ? 1 : 0;
return $isSame;
}

########## FormatTime ############
# Turn a floating Time::HiRes time into a string.
# The string is padded with leading zeros for easy string comparison,
# ensuring that $a lt $b iff $a < $b.
# An empty string "" will be returned if the time is 0.
sub FormatTime
{
@_ == 1 or die;
my ($time) = @_;
return "" if !$time || $time == 0;
# Enough digits to work through year 2286:
my $lm = sprintf("%010.6f", $time);
length($lm) == 10+1+6 or croak "Too many digits in time!";
return $lm;
}

########## FormatCounter ############
# Format a counter for use in an LM string.
# The counter becomes the lowest order digits.
# The string is padded with leading zeros for easy string comparison,
# ensuring that $a lt $b iff $a < $b.
sub FormatCounter
{
@_ == 1 or die;
my ($counter) = @_;
$counter = 0 if !$counter;
my $counterWidth = 6;
my $sCounter = sprintf("%0$counterWidth" . "d", $counter);
croak "Need more than $counterWidth digits in counter!"
	if length($sCounter) > $counterWidth;
return $sCounter;
}

########## TimeToLM ############
# Turn a floating Time::HiRes time (and optional counter) into an LM string, 
# for use in headers, etc.  The counter becomes the lowest order digits.
# The string is padded with leading zeros for easy string comparison,
# ensuring that $a lt $b iff $a < $b.
# An empty string "" will be returned if the time is 0.
# As generated, these are monotonic.  But in general the system does
# not require LMs to be monotonic, because they could be checksums.
# The only guarantee that the system requires is that they change
# if a node output has changed.
sub TimeToLM
{
@_ == 1 || @_ == 2 or die;
my ($time, $counter) = @_;
$counter = 0 if !$counter;
return "" if !$time;
return &FormatTime($time) . &FormatCounter($counter);
}

########## LMToHeaders ############
# Turn LM (high-res last-modified) into Last-Modified and ETag headers.
# The ETag header that is generated is formatted assuming that it is
# a strong ETag, i.e., it will not have a preceding "W/".
sub LMToHeaders
{
@_ == 1 or die;
# $lm should actually be a float represented as a string -- not a 
# float -- to ease comparison and avoid accidentally dropping decimal places.
my ($lm) = @_;
return("", "") if !$lm;
my $lmHeader = time2str($lm);
# ETag syntax:
# http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.11
# and quoted-string at the end of sec 2.2:
# http://www.w3.org/Protocols/rfc2616/rfc2616-sec2.html#sec2.2
my $eTagHeader = '"' . $lm . '"';
return($lmHeader, $eTagHeader);
}

########## HeadersToLM ############
# Turn Last-Modified and ETag headers into LM (high-res last-modified).
# This is round-trippable if it was generated by LMToHeaders.  
# It is a a one-way operation (i.e., not round-trippable) if something
# else generated the ETag.
sub HeadersToLM
{
@_ == 2 or die;
my ($lmHeader, $eTagHeader) = @_;
my $lm = "";
$lm = &TimeToLM(str2time($lmHeader)) if $lmHeader;
# ETag syntax:
# http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.11
# and quoted-string at the end of sec 2.2:
# http://www.w3.org/Protocols/rfc2616/rfc2616-sec2.html#sec2.2
if ($eTagHeader) {
  if ($eTagHeader =~ m|\A(W\/)?\"(.*)\"\Z|) {
    $lm = $2;
    }
  else {
    &Warn("WARNING: Bad ETag header received: $eTagHeader ");
    }
  }
return $lm;
}

############## PrintNodeMetadata ################
sub PrintNodeMetadata
{
my $nm = shift || die;
my $nmv = $nm->{value};
my $nml = $nm->{list};
my $nmh = $nm->{hash};
&PrintLog("Node Metadata:\n") if $debug;
my %allSubjects = (%{$nmv}, %{$nml}, %{$nmh});
foreach my $s (sort keys %allSubjects) {
	last if !$debug;
	my %allPredicates = ();
	%allPredicates = (%allPredicates, %{$nmv->{$s}}) if $nmv->{$s};
	%allPredicates = (%allPredicates, %{$nml->{$s}}) if $nml->{$s};
	%allPredicates = (%allPredicates, %{$nmh->{$s}}) if $nmh->{$s};
	foreach my $p (sort keys %allPredicates) {
		if ($nmv && $nmv->{$s} && $nmv->{$s}->{$p}) {
		  my $v = $nmv->{$s}->{$p};
		  &PrintLog("  $s -> $p -> $v\n");
		  }
		if ($nml && $nml->{$s} && $nml->{$s}->{$p}) {
		  my @vList = @{$nml->{$s}->{$p}};
		  my $vl = join(" ", @vList);
		  &PrintLog("  $s -> $p -> ($vl)\n");
		  }
		if ($nmh && $nmh->{$s} && $nmh->{$s}->{$p}) {
		  my %vHash = %{$nmh->{$s}->{$p}};
		  my @vHash = map {($_,$vHash{$_})} sort keys %vHash;
		  # @vHash = map {defined($_) ? $_ : '*undef*'} @vHash;
		  my $vh = join(" ", @vHash);
		  &PrintLog("  $s -> $p -> {$vh}\n");
		  }
		}
	}
}

##### DO NOT DELETE THE FOLLOWING TWO LINES!  #####
1;
__END__

=head1 NAME

RDF::Pipeline - Perl extension for blah blah blah

=head1 SYNOPSIS

  use RDF::Pipeline;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for RDF::Pipeline, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.


=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

David Booth, E<lt>dbooth@E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2011 & 2012 David Booth <david@dbooth.org>
See license information at http://code.google.com/p/rdf-pipeline/ 

=cut

