#!/usr/bin/perl -w

#    Copyright 2004-2005 Corey Goldberg (corey@goldb.org)
#
#    This file is part of WebInject.
#
#    WebInject is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    WebInject is distributed in the hope that it will be useful,
#    but without any warranty; without even the implied warranty of
#    merchantability or fitness for a particular purpose.  See the
#    GNU General Public License for more details.


our $version="1.35";

use strict;
use LWP;
use HTTP::Request::Common;
use HTTP::Cookies;
use XML::Simple;
use Time::HiRes 'time','sleep';
use Getopt::Long;
use Crypt::SSLeay;  #for SSL/HTTPS (you may comment this out if you don't need it)
#use Data::Dumper;  #uncomment to dump hashes for debugging   


$| = 1; #don't buffer output to STDOUT


our ($timestamp, $dirname);
our ($parseresponse, $parseresponse1, $parseresponse2, $parseresponse3, $parseresponse4, $parseresponse5,  
        $parsedresult, $parsedresult1, $parsedresult2, $parsedresult3, $parsedresult4, $parsedresult5);
our ($logresponse ,$logrequest);
our ($useragent, $request, $response);
our ($gui, $monitorenabledchkbx, $latency);
our ($cookie_jar, $proxy, $timeout, @httpauth);
our ($xnode, $graphtype, $plotclear, $stop, $nooutput);
our ($runcount, $totalruncount, $casepassedcount, $casefailedcount, $passedcount, $failedcount);
our ($totalresponse, $avgresponse, $maxresponse, $minresponse);
our (@casefilelist, $currentcasefile, $casecount, $isfailure);
our ($verifyresponsecode);
our ($verifypositive, $verifylater, $verifynegative, $verifylaterneg);
our ($url, $baseurl, $postbody, $posttype);
our ($gnuplot, $standaloneplot, $globalhttplog);
our ($currentdatetime, $totalruntime, $starttimer, $endtimer);
our ($opt_configfile, $opt_version);
our ($reporttype, $returnmessage, $errormessage, $globaltimeout, %exit_codes);


if (($0 =~ /webinject.pl/) or ($0 =~ /webinject.exe/)) {  #set flag so we know if it is running standalone or from webinjectgui
    $gui = 0; 
    engine();
}
else {
    $gui = 1;
    whackoldfiles(); #delete files leftover from previous run (do this here so they are whacked on startup when running from gui)
}



#------------------------------------------------------------------
sub engine {   #wrap the whole engine in a subroutine so it can be integrated with the gui 
      
    our ($sleep, $startruntimer, $endruntimer, $repeat);
    our ($curgraphtype);
    our ($casefilecheck, $testnum, $xmltestcases);
    our ($verifypositivenext, $verifynegativenext, $description1, $description2, $method);
        
    if ($gui == 1) { gui_initial(); }
        
    #get the directory webinject engine is running from   
    $dirname = $0;    
    $dirname =~ s|(.*/).*|$1|;  #for nix systems
    $dirname =~ s|(.*\\).*|$1|; #for windoz systems   
    if ($dirname eq $0) { 
        $dirname = './'; 
    }
        
    getoptions();  #get command line options
        
    #delete files leftover from previous run (do this here so they are whacked each run)
    whackoldfiles();
        
    #contsruct objects
    $useragent = LWP::UserAgent->new;
    $cookie_jar = HTTP::Cookies->new;
    $useragent->agent('WebInject');  #http useragent that will show up in webserver logs
    $useragent->max_redirect('0');  #don't follow redirects for GET's (POST's already don't follow, by default)
        
        
    if ($gui != 1){   
        $graphtype = 'lines'; #default to line graph if not in GUI
        $standaloneplot = 'off'; #initialize so we don't get warnings when <standaloneplot> is not set in config         
    }
        
    processcasefile();
        
    #add proxy support if it is set in config.xml
    if ($proxy) {
        $useragent->proxy(['http', 'https'], "$proxy")
    } 
        
    #add http basic authentication support
    #corresponds to:
    #$useragent->credentials('servername:portnumber', 'realm-name', 'username' => 'password');
    if (@httpauth) {
        $useragent->credentials("$httpauth[0]:$httpauth[1]", "$httpauth[2]", "$httpauth[3]" => "$httpauth[4]");
    }
        
    #change response delay timeout in seconds if it is set in config.xml      
    if ($timeout) {
        $useragent->timeout("$timeout");  #default LWP timeout is 180 secs.
    }
        
    #open file handles
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode   
        open(HTTPLOGFILE, ">$dirname"."http.log") or die "\nERROR: Failed to open http.log file\n\n";   
        open(RESULTS, ">$dirname"."results.html") or die "\nERROR: Failed to open results.html file\n\n";    
        open(RESULTSXML, ">$dirname"."results.xml") or die "\nERROR: Failed to open results.xml file\n\n";
    }
        
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
        print RESULTSXML qq|<results>\n\n|;  #write initial xml tag
        writeinitialhtml();  #write opening tags for results file
    }
               
    unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set 
        writeinitialstdout();  #write opening tags for STDOUT. 
    }
        
    if ($gui == 1){ $curgraphtype = $graphtype; }  #set the initial value so we know if the user changes the graph setting from the gui
        
    gnuplotcfg(); #create the gnuplot config file
        
        
    $totalruncount = 0;
    $casepassedcount = 0;
    $casefailedcount = 0;
    $passedcount = 0;
    $failedcount = 0;
    $totalresponse = 0;
    $avgresponse = 0;
    $maxresponse = 0;
    $minresponse = 10000000; #set to large value so first minresponse will be less
    $stop = 'no';
    $plotclear = 'no';
        
        
    $currentdatetime = localtime time;  #get current date and time for results report
    $startruntimer = time();  #timer for entire test run
        
        
    foreach (@casefilelist) { #process test case files named in config
        
        $currentcasefile = $_;
        #print "\n$currentcasefile\n\n";
            
        $casefilecheck = ' ';
            
        if ($gui == 1){ gui_processing_msg(); }
            
        convtestcases();
            
        fixsinglecase();
            
        $xmltestcases = XMLin("$dirname"."/$currentcasefile"); #slurp test case file to parse
        #print Dumper($xmltestcases);  #for debug, dump hash of xml   
        #print keys %{$configfile};  #for debug, print keys from dereferenced hash
            
        cleancases();
            
        $repeat = $xmltestcases->{repeat};  #grab the number of times to iterate test case file
        unless ($repeat) { $repeat = 1; }  #set to 1 in case it is not defined in test case file               
            
            
        foreach (1 .. $repeat) {
                
            $runcount = 0;
            
            foreach (sort {$a<=>$b} keys %{$xmltestcases->{case}}) {  #process cases in sorted order
                    
                $testnum = $_;
                    
                if ($xnode) {  #if an XPath Node is defined, only process the single Node 
                    $testnum = $xnode; 
                }
                 
                $isfailure = 0;
                    
                if ($gui == 1){
                    unless ($monitorenabledchkbx eq 'monitor_off') {  #don't do this if monitor is disabled in gui
                        if ("$curgraphtype" ne "$graphtype") {  #check to see if the user changed the graph setting
                            gnuplotcfg();  #create the gnuplot config file since graph setting changed
                            $curgraphtype = $graphtype;
                        }
                    }
                }
                    
                $timestamp = time();  #used to replace parsed {timestamp} with real timestamp value
                    
                if ($verifypositivenext) { $verifylater = $verifypositivenext; }  #grab $verifypositivenext string from previous test case (if it exists)
                if ($verifynegativenext) { $verifylaterneg = $verifynegativenext; }  #grab $verifynegativenext string from previous test case (if it exists)
                    
                #populate variables with values from testcase file, do substitutions, and revert converted values back
                $description1 = $xmltestcases->{case}->{$testnum}->{description1}; if ($description1) { convertbackxml($description1); } if ($gui == 1){ gui_tc_descript(); }
                $description2 = $xmltestcases->{case}->{$testnum}->{description2}; if ($description2) { convertbackxml($description2); }  
                $method = $xmltestcases->{case}->{$testnum}->{method}; if ($method) { convertbackxml($method); }  
                $url = $xmltestcases->{case}->{$testnum}->{url}; if ($url) { convertbackxml($url); }  
                $postbody = $xmltestcases->{case}->{$testnum}->{postbody}; if ($postbody) { convertbackxml($postbody); }  
                $posttype = $xmltestcases->{case}->{$testnum}->{posttype}; if ($posttype) { convertbackxml($posttype); }  
                $verifypositive = $xmltestcases->{case}->{$testnum}->{verifypositive}; if ($verifypositive) { convertbackxml($verifypositive); }  
                $verifynegative = $xmltestcases->{case}->{$testnum}->{verifynegative}; if ($verifynegative) { convertbackxml($verifynegative); }  
                $verifypositivenext = $xmltestcases->{case}->{$testnum}->{verifypositivenext}; if ($verifypositivenext) { convertbackxml($verifypositivenext); }  
                $verifynegativenext = $xmltestcases->{case}->{$testnum}->{verifynegativenext}; if ($verifynegativenext) { convertbackxml($verifynegativenext); }  
                $verifyresponsecode = $xmltestcases->{case}->{$testnum}->{verifyresponsecode}; if ($verifyresponsecode) { convertbackxml($verifyresponsecode); }  
                $parseresponse = $xmltestcases->{case}->{$testnum}->{parseresponse}; if ($parseresponse) { convertbackxml($parseresponse); }  
                $parseresponse1 = $xmltestcases->{case}->{$testnum}->{parseresponse1}; if ($parseresponse1) { convertbackxml($parseresponse1); }
                $parseresponse2 = $xmltestcases->{case}->{$testnum}->{parseresponse2}; if ($parseresponse2) { convertbackxml($parseresponse2); } 
                $parseresponse3 = $xmltestcases->{case}->{$testnum}->{parseresponse3}; if ($parseresponse3) { convertbackxml($parseresponse3); } 
                $parseresponse4 = $xmltestcases->{case}->{$testnum}->{parseresponse4}; if ($parseresponse4) { convertbackxml($parseresponse4); } 
                $parseresponse5 = $xmltestcases->{case}->{$testnum}->{parseresponse5}; if ($parseresponse5) { convertbackxml($parseresponse5); } 
                $logrequest = $xmltestcases->{case}->{$testnum}->{logrequest}; if ($logrequest) { convertbackxml($logrequest); }  
                $logresponse = $xmltestcases->{case}->{$testnum}->{logresponse}; if ($logresponse) { convertbackxml($logresponse); }  
                $sleep = $xmltestcases->{case}->{$testnum}->{sleep}; if ($sleep) { convertbackxml($sleep); }
                $errormessage = $xmltestcases->{case}->{$testnum}->{errormessage}; if ($errormessage) { convertbackxml($errormessage); }    
                    
                    
                if ($description1) {  #if we hit a dummy record, skip it
                    if ($description1 =~ /dummy test case/) {
                        next;
                    }
                }
                    
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
                    print RESULTS qq|<b>Test:  $currentcasefile - $testnum </b><br />\n|;
                }
                    
                unless ($nooutput) { #skip regular STDOUT output 
                    print STDOUT qq|Test:  $currentcasefile - $testnum \n|;
                }
                    
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode     
                    unless ($casefilecheck eq $currentcasefile) {
                        unless ($currentcasefile eq $casefilelist[0]) {  #if this is the first test case file, skip printing the closing tag for the previous one
                            print RESULTSXML qq|    </testcases>\n\n|;
                        }
                        print RESULTSXML qq|    <testcases file="$currentcasefile">\n\n|;
                    }
                    print RESULTSXML qq|        <testcase id="$testnum">\n|;
                }
                    
                if ($description1) {
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
                        print RESULTS qq|$description1 <br />\n|; 
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|$description1 \n|;
                        }
                        print RESULTSXML qq|            <description1>$description1</description1>\n|;
                    }
                }
                    
                if ($description2) {
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
                        print RESULTS qq|$description2 <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|$description2 \n|;
                        }
                        print RESULTSXML qq|            <description2>$description2</description2>\n|;
                    }
                }
                    
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                    print RESULTS qq|<br />\n|;
                }
                    
                if ($verifypositive) {
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
                        print RESULTS qq|Verify: "$verifypositive" <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|Verify: "$verifypositive" \n|;
                        }
                        print RESULTSXML qq|            <verifypositive>$verifypositive</verifypositive>\n|;
                    }
                }
                    
                if ($verifynegative) { 
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTS qq|Verify Negative: "$verifynegative" <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|Verify Negative: "$verifynegative" \n|;
                        }
                        print RESULTSXML qq|            <verifynegative>$verifynegative</verifynegative>\n|;
                    }
                }
                    
                if ($verifypositivenext) { 
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTS qq|Verify On Next Case: "$verifypositivenext" <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output  
                            print STDOUT qq|Verify On Next Case: "$verifypositivenext" \n|;
                        }
                        print RESULTSXML qq|            <verifypositivenext>$verifypositivenext</verifypositivenext>\n|;
                    }
                }
                    
                if ($verifynegativenext) { 
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTS qq|Verify Negative On Next Case: "$verifynegativenext" <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output  
                            print STDOUT qq|Verify Negative On Next Case: "$verifynegativenext" \n|;
                        }
                        print RESULTSXML qq|            <verifynegativenext>$verifynegativenext</verifynegativenext>\n|;
                    }
                }
                    
                if ($verifyresponsecode) {
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode 
                        print RESULTS qq|Verify Response Code: "$verifyresponsecode" <br />\n|;
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|Verify Response Code: "$verifyresponsecode" \n|;
                        }
                        print RESULTSXML qq|            <verifyresponsecode>$verifyresponsecode</verifyresponsecode>\n|;
                    }
                }
                    
                    
                if ($method) {
                    if ($method eq "get") { httpget(); }
                    elsif ($method eq "post") { httppost(); }
                    else { print STDERR qq|ERROR: bad HTTP Request Method Type, you must use "get" or "post"\n|; }
                }
                else {   
                    httpget();  #use "get" if no method is specified  
                }  
                    
                    
                verify();  #verify result from http response
                    
                httplog();  #write to http.log file
                    
                plotlog($latency);  #send perf data to log file for plotting
                    
                plotit();  #call the external plotter to create a graph
                 
                if ($gui == 1) { 
                    gui_updatemontab();  #update monitor with the newly rendered plot graph 
                }   
                    
                    
                parseresponse();  #grab string from response to send later
                    
                    
                if ($isfailure > 0) {  #if any verification fails, test case is considered a failure
                    if ($errormessage) { #Add defined error message to the output 
                        unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                            print RESULTS qq|<b><span class="fail">TEST CASE FAILED : $errormessage</span></b><br />\n|;
                        }
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|TEST CASE FAILED : $errormessage\n|;
                        }
                    }
                    else { #print regular error output
                        unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                            print RESULTS qq|<b><span class="fail">TEST CASE FAILED</span></b><br />\n|;
                        }
                        unless ($nooutput) { #skip regular STDOUT output 
                            print STDOUT qq|TEST CASE FAILED\n|;
                        }
                    }    
                    unless ($returnmessage) {  #(used for plugin compatibility) if it's the first error message, set it to variable
                        if ($errormessage) { 
                            $returnmessage = $errormessage; 
                        }
                        else { 
                            $returnmessage = "Test case number $testnum failed"; 
                        }
                        #print "\nReturn Message : $returnmessage\n"
                    }
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTSXML qq|            <success>false</success>\n|;
                    }
                    if ($gui == 1){ 
                        gui_status_failed();
                    }
                    $casefailedcount++;
                }
                else {
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTS qq|<b><span class="pass">TEST CASE PASSED</span></b><br />\n|;
                    }
                    unless ($nooutput) { #skip regular STDOUT output 
                        print STDOUT qq|TEST CASE PASSED \n|;
                    }
                    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                        print RESULTSXML qq|            <success>true</success>\n|;
                    }
                    if ($gui == 1){
                        gui_status_passed(); 
                    }
                    $casepassedcount++;
                }
                    
                    
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                    print RESULTS qq|Response Time = $latency sec <br />\n|;
                }
                    
                if ($gui == 1) { gui_timer_output(); } 
                    
                unless ($nooutput) { #skip regular STDOUT output 
                    print STDOUT qq|Response Time = $latency sec \n|;
                }
                    
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                    print RESULTSXML qq|            <responsetime>$latency</responsetime>\n|;
                    print RESULTSXML qq|        </testcase>\n\n|;
                    print RESULTS qq|<br />\n------------------------------------------------------- <br />\n\n|;
                }
                    
                unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set   
                    print STDOUT qq|------------------------------------------------------- \n|;
                }
                    
                $casefilecheck = $currentcasefile;  #set this so <testcases> xml is only closed after each file is done processing
                   
                $endruntimer = time();
                $totalruntime = (int(1000 * ($endruntimer - $startruntimer)) / 1000);  #elapsed time rounded to thousandths 
                    
                $runcount++;    
                $totalruncount++;
                    
                if ($gui == 1) { 
                    gui_statusbar();  #update the statusbar
                }   
                    
                if ($latency > $maxresponse) { $maxresponse = $latency; }  #set max response time
                if ($latency < $minresponse) { $minresponse = $latency; }  #set min response time
                $totalresponse = ($totalresponse + $latency);  #keep total of response times for calculating avg 
                $avgresponse = (int(1000 * ($totalresponse / $totalruncount)) / 1000);  #avg response rounded to thousandths
                    
                if ($gui == 1) { gui_updatemonstats(); }  #update timers and counts in monitor tab   
                    
                #break from sub if user presses stop button in gui    
                if ($stop eq 'yes') {
                    finaltasks();
                    $stop = 'no';
                    return;  #break from sub
                }
                    
                if ($sleep) {  #if a sleep value is set in the test case, sleep that amount
                    sleep($sleep)
                }
                    
                if ($xnode) {  #if an XPath Node is defined, only process the single Node 
                    last;
                }
                    
            }
                
            $testnum = 1;  #reset testcase counter so it will reprocess test case file if repeat is set
        }
    }
        
    finaltasks();  #do return/cleanup tasks
        
} #end engine subroutine



#------------------------------------------------------------------
#  SUBROUTINES
#------------------------------------------------------------------
sub writeinitialhtml {  #write opening tags for results file
        
    print RESULTS 
qq|<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">

<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>WebInject Test Results</title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
    <style type="text/css">
        body {
            background-color: #F5F5F5;
            color: #000000;
            font-family: Verdana, Arial, Helvetica, sans-serif; 
            font-size: 10px;
        }
        .pass { color: green }
        .fail { color: red }
    </style>
</head>
<body>
<hr />
-------------------------------------------------------<br />
|; 
}
#------------------------------------------------------------------
sub writeinitialstdout {  #write initial text for STDOUT
        
    print STDOUT 
qq|
Starting WebInject Engine...

-------------------------------------------------------
|; 
}
#------------------------------------------------------------------
sub writefinalhtml {  #write summary and closing tags for results file
        
    print RESULTS
qq|    
<br /><hr /><br />
<b>
Start Time: $currentdatetime <br />
Total Run Time: $totalruntime seconds <br />
<br />
Test Cases Run: $totalruncount <br />
Test Cases Passed: $casepassedcount <br />
Test Cases Failed: $casefailedcount <br />
Verifications Passed: $passedcount <br />
Verifications Failed: $failedcount <br />
<br />
Average Response Time: $avgresponse seconds <br />
Max Response Time: $maxresponse seconds <br />
Min Response Time: $minresponse seconds <br />
</b>
<br />

</body>
</html>
|; 
}
#------------------------------------------------------------------
sub writefinalstdout {  #write summary and closing text for STDOUT
        
    print STDOUT
qq|    
Start Time: $currentdatetime
Total Run Time: $totalruntime seconds

Test Cases Run: $totalruncount
Test Cases Passed: $casepassedcount
Test Cases Failed: $casefailedcount 
Verifications Passed: $passedcount
Verifications Failed: $failedcount

|; 
}
#------------------------------------------------------------------
sub httpget {  #send http request and read response
        
    $request = new HTTP::Request('GET',"$url");
        
    $cookie_jar->add_cookie_header($request);
    #print $request->as_string; print "\n\n";
        
    $starttimer = time();
    $response = $useragent->request($request);
    $endtimer = time();
    $latency = (int(1000 * ($endtimer - $starttimer)) / 1000);  #elapsed time rounded to thousandths 
    #print $response->as_string; print "\n\n";
        
    $cookie_jar->extract_cookies($response);
    #print $cookie_jar->as_string; print "\n\n";
}
#------------------------------------------------------------------
sub httppost {  #post request based on specified encoding
        
    if ($posttype) {
	if ($posttype eq 'application/x-www-form-urlencoded') { httppost_form_urlencoded(); }
        elsif ($posttype eq 'multipart/form-data') { httppost_form_data(); }
        else { print STDERR qq|ERROR: Bad Form Encoding Type, you must use "application/x-www-form-urlencoded" or "multipart/form-data"\n|; }
    }
    else {   
        $posttype = 'application/x-www-form-urlencoded';
        httppost_form_urlencoded();  #use "x-www-form-urlencoded" if no encoding is specified  
    } 
}
#------------------------------------------------------------------
sub httppost_form_urlencoded {  #send application/x-www-form-urlencoded HTTP request and read response
        
    $request = new HTTP::Request('POST',"$url");
    $request->content_type("$posttype");
    $request->content("$postbody");
    $cookie_jar->add_cookie_header($request);
    #print $request->as_string; print "\n\n";
    $starttimer = time();
    $response = $useragent->request($request);
    $endtimer = time();
    $latency = (int(1000 * ($endtimer - $starttimer)) / 1000);  #elapsed time rounded to thousandths 
    #print $response->as_string; print "\n\n";
        
    $cookie_jar->extract_cookies($response);
    #print $cookie_jar->as_string; print "\n\n";
}
#------------------------------------------------------------------
sub httppost_form_data {  #send multipart/form-data HTTP request and read response
	
    my %myContent_;
    eval "\%myContent_ = $postbody";
    $request = POST "$url",
               Content_Type => "$posttype",
               Content => \%myContent_;
    $cookie_jar->add_cookie_header($request);
    #print $request->as_string; print "\n\n";
    $starttimer = time();
    $response = $useragent->request($request);
    $endtimer = time();
    $latency = (int(1000 * ($endtimer - $starttimer)) / 1000);  #elapsed time rounded to thousandths 
    #print $response->as_string; print "\n\n";
        
    $cookie_jar->extract_cookies($response);
    #print $cookie_jar->as_string; print "\n\n";
}
#------------------------------------------------------------------
sub verify {  #do verification of http response and print status to HTML/XML/STDOUT/UI
        
    if ($verifypositive) {
        if ($response->as_string() =~ /$verifypositive/si) {  #verify existence of string in response
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed Positive Verification</span><br />\n|;
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT "Passed Positive Verification \n";
            }
            $passedcount++;
        }
        else {
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="fail">Failed Positive Verification</span><br />\n|;
            }
            unless ($nooutput) { #skip regular STDOUT output  
                print STDOUT "Failed Positive Verification \n";         
            }
            $failedcount++;
            $isfailure++;
        }
    }
        
        
        
    if ($verifynegative) {
        if ($response->as_string() =~ /$verifynegative/si) {  #verify existence of string in response
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="fail">Failed Negative Verification</span><br />\n|;
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT "Failed Negative Verification \n";            
            }
            $failedcount++;
            $isfailure++;
        }
        else {
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed Negative Verification</span><br />\n|;
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT "Passed Negative Verification \n";
            }
            $passedcount++;                
        }
    }
        
        
        
    if ($verifylater) {
        if ($response->as_string() =~ /$verifylater/si) {  #verify existence of string in response
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed Positive Verification (verification set in previous test case)</span><br />\n|;
            }
            unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set 
                print STDOUT "Passed Positive Verification (verification set in previous test case) \n";
            }
            $passedcount++;
        }
        else {
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="fail">Failed Positive Verification (verification set in previous test case)</span><br />\n|;
            }
            unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set 
                print STDOUT "Failed Positive Verification (verification set in previous test case) \n";            
            }
            $failedcount++;
            $isfailure++;            
        }        
        $verifylater = '';  #set to null after verification
    }
        
        
        
    if ($verifylaterneg) {
        if ($response->as_string() =~ /$verifylaterneg/si) {  #verify existence of string in response
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="fail">Failed Negative Verification (negative verification set in previous test case)</span><br />\n|;
            }
            unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set  
                print STDOUT "Failed Negative Verification (negative verification set in previous test case) \n";     
            }
            $failedcount++;
            $isfailure++;
        }
        else {
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed Negative Verification (negative verification set in previous test case)</span><br />\n|;
            }
            unless ($xnode or $nooutput) { #skip regular STDOUT output if using an XPath or $nooutput is set 
                print STDOUT "Passed Negative Verification (negative verification set in previous test case) \n";
            }
            $passedcount++;                   
        }
        $verifylaterneg = '';  #set to null after verification
    }
        
     
     
    if ($verifyresponsecode) {
        if ($verifyresponsecode == $response->code()) { #verify returned HTTP response code matches verifyresponsecode set in test case
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed HTTP Response Code Verification </span><br />\n|; 
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT qq|Passed HTTP Response Code Verification \n|; 
            }
            $passedcount++;         
            }
        else {
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="fail">Failed HTTP Response Code Verification (received | . $response->code() .  qq|, expecting $verifyresponsecode)</span><br />\n|;
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT qq|Failed HTTP Response Code Verification (received | . $response->code() .  qq|, expecting $verifyresponsecode) \n|;
            }
            $failedcount++;
            $isfailure++;
        }
    }
    else { #verify http response code is in the 100-399 range
        if ($response->as_string() =~ /HTTP\/1.(0|1) (1|2|3)/i) {  #verify existance of string in response
            unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                print RESULTS qq|<span class="pass">Passed HTTP Response Code Verification (not in error range)</span><br />\n|; 
            }
            unless ($nooutput) { #skip regular STDOUT output 
                print STDOUT qq|Passed HTTP Response Code Verification (not in error range) \n|; 
            }
            #succesful response codes: 100-399
            $passedcount++;         
        }
        else {
            $response->as_string() =~ /(HTTP\/1.)(.*)/i;
            if ($1) {  #this is true if an HTTP response returned 
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                    print RESULTS qq|<span class="fail">Failed HTTP Response Code Verification ($1$2)</span><br />\n|; #($1$2) is HTTP response code
                }
                unless ($nooutput) { #skip regular STDOUT output 
                    print STDOUT "Failed HTTP Response Code Verification ($1$2) \n"; #($1$2) is HTTP response code   
                }
            }
            else {  #no HTTP response returned.. could be error in connection, bad hostname/address, or can not connect to web server
                unless ($reporttype) {  #we suppress most logging when running in a plugin mode
                    print RESULTS qq|<span class="fail">Failed - No Response</span><br />\n|; #($1$2) is HTTP response code
                }
                unless ($nooutput) { #skip regular STDOUT output  
                    print STDOUT "Failed - No Response \n"; #($1$2) is HTTP response code   
                }
            }
            $failedcount++;
            $isfailure++;
        }
    }        
}
#------------------------------------------------------------------
sub parseresponse {  #parse values from responses for use in future request (for session id's, dynamic URL rewriting, etc)
        
    our ($resptoparse, @parseargs);
    our ($leftboundary, $rightboundary, $escape);
     
     
    if ($parseresponse) {
           
        @parseargs = split(/\|/, $parseresponse);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult = $1; 
        }
            
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult = url_escape($parsedresult);
            }
        }
        #print "\n\nParsed String: $parsedresult\n\n";
    }
        
        
    if ($parseresponse1) {
            
        @parseargs = split(/\|/, $parseresponse1);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult1 = $1; 
        }
            
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult1 = url_escape($parsedresult1);
            }
        }
        #print "\n\nParsed String: $parsedresult1\n\n";
    }
        
        
    if ($parseresponse2) {
            
        @parseargs = split(/\|/, $parseresponse2);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult2 = $1; 
        }
            
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult2 = url_escape($parsedresult2);
            }
        }
        #print "\n\nParsed String: $parsedresult2\n\n";
    }
        
        
    if ($parseresponse3) {
            
        @parseargs = split(/\|/, $parseresponse3);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult3 = $1; 
        }
            
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult3 = url_escape($parsedresult3);
            }
        }
        #print "\n\nParsed String: $parsedresult3\n\n";
    }
    
    
    if ($parseresponse4) {
            
        @parseargs = split(/\|/, $parseresponse4);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult4 = $1; 
        }
        
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult4 = url_escape($parsedresult4);
            }
        }           
        #print "\n\nParsed String: $parsedresult4\n\n";
    }
        
        
    if ($parseresponse5) {
            
        @parseargs = split(/\|/, $parseresponse5);
            
        $leftboundary = $parseargs[0]; $rightboundary = $parseargs[1]; $escape = $parseargs[2];
            
        $resptoparse = $response->as_string;
        if ($resptoparse =~ /$leftboundary(.*?)$rightboundary/s) {
            $parsedresult5 = $1; 
        }
            
        if ($escape) {
            if ($escape eq 'escape') {
                $parsedresult5 = url_escape($parsedresult5);
            }
        }
        #print "\n\nParsed String: $parsedresult5\n\n";
    }
        
}
#------------------------------------------------------------------
sub processcasefile {  #get test case files to run (from command line or config file) and evaluate constants
                       #parse config file and grab values it sets 
        
    my @configfile;
    my $configexists = 0;
    my $comment_mode;
    my $firstparse;
    my $filename;
    my $xpath;
    my $setuseragent;
        
    undef @casefilelist; #empty the array of test case filenames
    undef @configfile;
        
    #process the config file
    if ($opt_configfile) {  #if -c option was set on command line, use specified config file
        open(CONFIG, "$dirname"."$opt_configfile") or die "\nERROR: Failed to open $opt_configfile file\n\n";
        $configexists = 1;  #flag we are going to use a config file
    }
    elsif (-e "$dirname"."config.xml") {  #if config.xml exists, read it
        open(CONFIG, "$dirname"."config.xml") or die "\nERROR: Failed to open config.xml file\n\n";
        $configexists = 1;  #flag we are going to use a config file
    } 
        
    if ($configexists) {  #if we have a config file, use it  
            
        my @precomment = <CONFIG>;  #read the config file into an array
            
        #remove any commented blocks from config file
         foreach (@precomment) {
            unless (m~<comment>.*</comment>~) {  #single line comment 
                #multi-line comments
                if (/<comment>/) {   
                    $comment_mode = 1;
                } 
                elsif (m~</comment>~) {   
                    $comment_mode = 0;
                } 
                elsif (!$comment_mode) {
                    push(@configfile, $_);
                }
            }
        }
    }
        
    if (($#ARGV + 1) < 1) {  #no command line args were passed  
        #if testcase filename is not passed on the command line, use files in config.xml  
        #parse test case file names from config.xml and build array
        foreach (@configfile) {
                
            if (/<testcasefile>/) {   
                $firstparse = $';  #print "$' \n\n";
                $firstparse =~ /<\/testcasefile>/;
                $filename = $`;  #string between tags will be in $filename
                #print "\n$filename \n\n";
                push @casefilelist, $filename;  #add next filename we grab to end of array
            }
        }    
            
        unless ($casefilelist[0]) {
            if (-e "$dirname"."testcases.xml") {
                #not appending a $dirname here since we append one when we open the file
                push @casefilelist, "testcases.xml";  #if no files are specified in config.xml, default to testcases.xml
            }
            else {
                die "\nERROR: I can't find any test case files to run.\nYou must either use a config file or pass a filename " . 
                    "on the command line if you are not using the default testcase file (testcases.xml).";
            }
        }
    }
        
    elsif (($#ARGV + 1) == 1) {  #one command line arg was passed
        #use testcase filename passed on command line (config.xml is only used for other options)
        push @casefilelist, $ARGV[0];  #first commandline argument is the test case file, put this on the array for processing
    }
        
    elsif (($#ARGV + 1) == 2) {  #two command line args were passed
            
        undef $xnode; #reset xnode
        undef $xpath; #reset xpath
            
        $xpath = $ARGV[1];
            
        if ($xpath =~ /\/(.*)\[/) {  #if the argument contains a "/" and "[", it is really an XPath  
            $xpath =~ /(.*)\/(.*)\[(.*?)\]/;  #if it contains XPath info, just grab the file name
            $xnode = $3;  #grab the XPath Node value.. (from inside the "[]")
            #print "\nXPath Node is: $xnode \n";
        }
        else {
            print STDERR "\nSorry, $xpath is not in the XPath format I was excpecting, I'm ignoring it...\n"; 
        }
            
        #use testcase filename passed on command line (config.xml is only used for other options)        
        push @casefilelist, $ARGV[0];  #first command line argument is the test case file, put this on the array for processing
    }
        
    elsif (($#ARGV + 1) > 2) {  #too many command line args were passed
        die "\nERROR: Too many arguments\n\n";
    }
        
    #print "\ntestcase file list: @casefilelist\n\n";
        
        
    #grab values for constants in config file:
    foreach (@configfile) {
            
        if (/<baseurl>/) {   
            $_ =~ /<baseurl>(.*)<\/baseurl>/;
            $baseurl = $1;
            #print "\nbaseurl : $baseurl \n\n";
        }
            
        if (/<proxy>/) {   
            $_ =~ /<proxy>(.*)<\/proxy>/;
            $proxy = $1;
            #print "\nproxy : $proxy \n\n";
        }
            
        if (/<timeout>/) {   
            $_ =~ /<timeout>(.*)<\/timeout>/;
            $timeout = $1;
            #print "\ntimeout : $timeout \n\n";
        }
            
        if (/<globaltimeout>/) {  #used in plugin integration
            $_ =~ /<globaltimeout>(.*)<\/globaltimeout>/;
            $globaltimeout = $1;
            #print "\nglobaltimeout : $globaltimeout \n\n";
        }
            
        if (/<reporttype>/) {   
            $_ =~ /<reporttype>(.*)<\/reporttype>/;
	    if ($1 ne "standard") {
               $reporttype = $1;
	       $nooutput = "set";
	    } 
            #print "\nreporttype : $reporttype \n\n";
        }    
            
        if (/<useragent>/) {   
            $_ =~ /<useragent>(.*)<\/useragent>/;
            $setuseragent = $1;
            if ($setuseragent) { #http useragent that will show up in webserver logs
                $useragent->agent($setuseragent);
            }  
            #print "\nuseragent : $setuseragent \n\n";
        }
         
        if (/<globalhttplog>/) {   
            $_ =~ /<globalhttplog>(.*)<\/globalhttplog>/;
            $globalhttplog = $1;
            #print "\nglobalhttplog : $globalhttplog \n\n";
        }
            
        if (/<gnuplot>/) {        
            $_ =~ /<gnuplot>(.*)<\/gnuplot>/;
            $gnuplot = $1;
            #print "\ngnuplot : $gnuplot \n\n";
        }
        
        if (/<standaloneplot>/) {        
            $_ =~ /<standaloneplot>(.*)<\/standaloneplot>/;
            $standaloneplot = $1;
            #print "\nstandaloneplot : $standaloneplot \n\n";
        }
            
        if (/<httpauth>/) {        
            $_ =~ /<httpauth>(.*)<\/httpauth>/;
            @httpauth = split(/:/, $1);
            if ($#httpauth != 4) {
                print STDERR "\nError: httpauth should have 5 fields delimited by colons\n\n"; 
                undef @httpauth;
            }
            #print "\nhttpauth : @httpauth \n\n";
        }
            
    }  
        
    close(CONFIG);
}
#------------------------------------------------------------------
sub fixsinglecase{ #xml parser creates a hash in a different format if there is only a single testcase.
                   #add a dummy testcase to fix this situation
        
    my @xmltoconvert;
        
    if ($casecount == 1) {
            
        open(XMLTOCONVERT, "$dirname"."$currentcasefile") or die "\nError: Failed to open test case file\n\n";  #open file handle   
        @xmltoconvert = <XMLTOCONVERT>;  #read the file into an array
            
        for(@xmltoconvert) { 
            s/<\/testcases>/<case id="2" description1="dummy test case"\/><\/testcases>/g;  #add dummy test case to end of file   
        }       
        close(XMLTOCONVERT);
            
        open(XMLTOCONVERT, ">$dirname"."$currentcasefile") or die "\nERROR: Failed to open test case file\n\n";  #open file handle   
        print XMLTOCONVERT @xmltoconvert;  #overwrite file with converted array
        close(XMLTOCONVERT);
    }
}
#------------------------------------------------------------------
sub convtestcases {  #convert ampersands and certain escaped chars so xml parser doesn't puke
        
    my @xmltoconvert;        
        
    open(XMLTOCONVERT, "$dirname"."$currentcasefile") or die "\nError: Failed to open test case file\n\n";  #open file handle   
    @xmltoconvert = <XMLTOCONVERT>;  #read the file into an array
        
    $casecount = 0;
        
    foreach (@xmltoconvert){ 
            
        #convert escaped chars and certain reserved chars to temporary values that the parser can handle
        #these are converted back later in processing
        s/&/{AMPERSAND}/g;  
        s/\\</{LESSTHAN}/g;      
            
        #count cases while we are here    
        if ($_ =~ /<case/) {  #count test cases based on '<case' tag
            $casecount++; 
        }    
    }  
        
    close(XMLTOCONVERT);   
        
    open(XMLTOCONVERT, ">$dirname"."$currentcasefile") or die "\nERROR: Failed to open test case file\n\n";  #open file handle   
    print XMLTOCONVERT @xmltoconvert;  #overwrite file with converted array
    close(XMLTOCONVERT);
}
#------------------------------------------------------------------
sub cleancases {  #cleanup conversions made to file for converted characters and single testcase instance
                  #this should leave the test case file exatly like it started
        
    my @xmltoconvert;
        
    open(XMLTOCONVERT, "$dirname"."$currentcasefile") or die "\nError: Failed to open test case file\n\n";  #open file handle   
    @xmltoconvert = <XMLTOCONVERT>;  #read the file into an array
        
    foreach (@xmltoconvert) { 
            
        s/{AMPERSAND}/&/g;
        s/{LESSTHAN}/\\</g; 
            
        s/<case id="2" description1="dummy test case"\/><\/testcases>/<\/testcases>/g;  #add dummy test case to end of file
    }  
        
    close(XMLTOCONVERT);   
        
    open(XMLTOCONVERT, ">$dirname"."$currentcasefile") or die "\nERROR: Failed to open test case file\n\n";  #open file handle   
    print XMLTOCONVERT @xmltoconvert;  #overwrite file with converted array
    close(XMLTOCONVERT);
}
#------------------------------------------------------------------
sub convertbackxml() {  #converts replaced xml with substitutions
        
    $_[0] =~ s/{AMPERSAND}/&/g;
    $_[0] =~ s/{LESSTHAN}/</g;
    $_[0] =~ s/{TIMESTAMP}/$timestamp/g;
    $_[0] =~ s/{BASEURL}/$baseurl/g;
    $_[0] =~ s/{PARSEDRESULT}/$parsedresult/g; 
    $_[0] =~ s/{PARSEDRESULT1}/$parsedresult1/g; 
    $_[0] =~ s/{PARSEDRESULT2}/$parsedresult2/g; 
    $_[0] =~ s/{PARSEDRESULT3}/$parsedresult3/g; 
    $_[0] =~ s/{PARSEDRESULT4}/$parsedresult4/g; 
    $_[0] =~ s/{PARSEDRESULT5}/$parsedresult5/g;
}
#------------------------------------------------------------------
sub url_escape {  #escapes difficult characters with %hexvalue
    #LWP handles url encoding already, but use this to escape valid chars that LWP won't convert (like +)
        
    my @a = @_;  #make a copy of the arguments
        
    map { s/[^-\w.,!~'()\/ ]/sprintf "%%%02x", ord $&/eg } @a;
    return wantarray ? @a : $a[0];
}
#------------------------------------------------------------------
sub httplog {  #write requests and responses to http.log file
        
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
        
        if ($logrequest && ($logrequest =~ /yes/i)) {  #http request - log setting per test case
            print HTTPLOGFILE $request->as_string, "\n\n";
        } 
            
        if ($logresponse && ($logresponse =~ /yes/i)) {  #http response - log setting per test case
            print HTTPLOGFILE $response->as_string, "\n\n";
        }
            
        if ($globalhttplog && ($globalhttplog =~ /yes/i)) {  #global http log setting
            print HTTPLOGFILE $request->as_string, "\n\n";
            print HTTPLOGFILE $response->as_string, "\n\n";
        }
            
        if (($globalhttplog && ($globalhttplog =~ /onfail/i)) && ($isfailure > 0)) { #global http log setting - onfail mode
            print HTTPLOGFILE $request->as_string, "\n\n";
            print HTTPLOGFILE $response->as_string, "\n\n";
        }
            
        if (($logrequest && ($logrequest =~ /yes/i)) or
            ($logresponse && ($logresponse =~ /yes/i)) or
            ($globalhttplog && ($globalhttplog =~ /yes/i)) or
            (($globalhttplog && ($globalhttplog =~ /onfail/i)) && ($isfailure > 0))
           ) {     
                print HTTPLOGFILE "\n************************* LOG SEPARATOR *************************\n\n\n";
        }
    }
}
#------------------------------------------------------------------
sub plotlog {  #write performance results to plot.log in the format gnuplot can use
        
    our (%months, $date, $time, $mon, $mday, $hours, $min, $sec, $year, $value);
        
    #do this unless: monitor is disabled in gui, or running standalone mode without config setting to turn on plotting     
    unless ((($gui == 1) and ($monitorenabledchkbx eq 'monitor_off')) or (($gui == 0) and ($standaloneplot ne 'on'))) {  
            
        %months = ("Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6, 
                   "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12);
            
        local ($value) = @_; 
        $date = scalar localtime; 
        ($mon, $mday, $hours, $min, $sec, $year) = $date =~ 
            /\w+ (\w+) +(\d+) (\d\d):(\d\d):(\d\d) (\d\d\d\d)/;
            
        $time = "$months{$mon} $mday $hours $min $sec $year";
            
        if ($plotclear eq 'yes') {  #used to clear the graph when requested
            open(PLOTLOG, ">$dirname"."plot.log") or die "ERROR: Failed to open file plot.log\n";  #open in clobber mode so log gets truncated
            $plotclear = 'no';  #reset the value 
        }
        else {
            open(PLOTLOG, ">>$dirname"."plot.log") or die "ERROR: Failed to open file plot.log\n";  #open in append mode
        }
          
        printf PLOTLOG "%s %2.4f\n", $time, $value;
        close(PLOTLOG);
    }    
}
#------------------------------------------------------------------
sub gnuplotcfg {  #create gnuplot config file
        
    #do this unless: monitor is disabled in gui, or running standalone mode without config setting to turn on plotting     
    unless ((($gui == 1) and ($monitorenabledchkbx eq 'monitor_off')) or (($gui == 0) and ($standaloneplot ne 'on'))) {  
        
        open(GNUPLOTPLT, ">$dirname"."plot.plt") || die "Could not open file\n";
        print GNUPLOTPLT qq|
set term png 
set output \"plot.png\"
set size 1.1,0.5
set pointsize .5
set xdata time 
set ylabel \"Response Time (seconds)\"
set yrange [0:]
set bmargin 2
set tmargin 2
set timefmt \"%m %d %H %M %S %Y\"
plot \"plot.log\" using 1:7 title \"Response Times" w $graphtype
|;      
        close(GNUPLOTPLT);
        
    }
}
#------------------------------------------------------------------
sub finaltasks {  #do ending tasks
        
    if ($gui == 1){ gui_stop(); }
        
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
        writefinalhtml();  #write summary and closing tags for results file
    }
        
    unless ($xnode or $reporttype) { #skip regular STDOUT output if using an XPath or $reporttype is set ("standard" does not set this) 
        writefinalstdout();  #write summary and closing tags for STDOUT
    }
        
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
        print RESULTSXML qq|    </testcases>\n\n</results>\n|;  #write final xml tag
    }
    
    unless ($reporttype) {  #we suppress most logging when running in a plugin mode
        #these handles shouldn't be open    
        close(HTTPLOGFILE);
        close(RESULTS);
        close(RESULTSXML);
    }    
        
        
    #plugin modes
    if ($reporttype) {  #return value is set which corresponds to a monitoring program
            
        #Nagios plugin compatibility
        if ($reporttype eq 'nagios') { #report results in Nagios format 
            #predefined exit codes for Nagios
            %exit_codes  = ('UNKNOWN' ,-1,
                            'OK'      , 0,
                            'WARNING' , 1,
                            'CRITICAL', 2,);
            if ($casefailedcount > 0) {
                print "WebInject CRITICAL - $returnmessage \n";
                exit $exit_codes{'CRITICAL'};
            }
            elsif (($globaltimeout) && ($totalruntime > $globaltimeout)) { 
                print "WebInject WARNING - All tests passed successfully but global timeout ($globaltimeout seconds) has been reached \n";
                exit $exit_codes{'WARNING'};
            }
            else { 
                print "WebInject OK - All tests passed successfully in $totalruntime seconds \n";
                exit $exit_codes{'OK'};
            }
        }
            
        #MRTG plugin compatibility
        elsif ($reporttype eq 'mrtg') { #report results in MRTG format 
            if ($casefailedcount > 0) {
                print "$totalruntime\n$totalruntime\n\nWebInject CRITICAL - $returnmessage \n";
                exit(0);
            }
            else { 
                print "$totalruntime\n$totalruntime\n\nWebInject OK - All tests passed successfully in $totalruntime seconds \n";
                exit(0);
            }
        }
            
        else {
            print STDERR "\nError: only 'nagios', 'mrtg', or 'standard' are supported reporttype values\n\n";
        }
            
    }
	
}
#------------------------------------------------------------------
sub whackoldfiles {  #delete any files leftover from previous run if they exist
        
    if (-e "plot.log") { unlink "plot.log"; } 
    if (-e "plot.plt") { unlink "plot.plt"; } 
    if (-e "plot.png") { unlink "plot.png"; }
        
    #verify files are deleted, if not give the filesystem time to delete them before continuing    
    while ((-e "plot.log") or (-e "plot.plt") or (-e "plot.png")) {
        sleep .5; 
    }
}
#------------------------------------------------------------------
sub plotit {  #call the external plotter to create a graph (if we are in the appropriate mode)
        
    #do this unless: monitor is disabled in gui, or running standalone mode without config setting to turn on plotting     
    unless ((($gui == 1) and ($monitorenabledchkbx eq 'monitor_off')) or (($gui == 0) and ($standaloneplot ne 'on'))) {
        unless ($graphtype eq 'nograph') {  #do this unless its being called from the gui with No Graph set
            if ($gnuplot) {  #if gnuplot is specified in config.xml, use it
                system "$gnuplot", "plot.plt";  #plot it with gnuplot
            }
            elsif (($^O eq 'MSWin32') and (-e './wgnupl32.exe')) {  #check for Win32 exe 
                system "wgnupl32.exe", "plot.plt";  #plot it with gnuplot using exe
            }
            elsif ($gui == 1) {
                gui_no_plotter_found();  #if gnuplot not specified, notify on gui
            }
        }
    }
}
#------------------------------------------------------------------
sub getoptions {  #command line options
        
    Getopt::Long::Configure('bundling');
    GetOptions(
        'v|version'     => \$opt_version,
        'c|config=s'    => \$opt_configfile,
        'n|no-output'   => \$nooutput,
        ) 
        or do {
            print_usage();
            exit();
        };
    if ($opt_version) {
	print "WebInject version $version\nFor more info: http://www.webinject.org\n";
  	exit();
    }
    sub print_usage {
        print <<EOB
    Usage:
      webinject.pl [-c|--config config_file] [-n|--no-output] [testcase_file [XPath]]
      webinject.pl --version|-v
EOB
    }
}
#------------------------------------------------------------------
