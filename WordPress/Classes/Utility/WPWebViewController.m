#import "WPWebViewController.h"
#import "WordPressAppDelegate.h"
#import "ReachabilityUtils.h"
#import "WPActivityDefaults.h"
#import "WPURLRequest.h"
#import "WPUserAgent.h"
#import "WPCookie.h"
#import "Constants.h"
#import "WPError.h"
#import "WPStyleGuide+WebView.h"
#import <WordPressShared/UIImage+Util.h>
#import <WordPressShared/UIDevice+Helpers.h>
#import "WordPress-Swift.h"

@import Gridicons;

#pragma mark - Constants

static NSInteger const WPWebViewErrorAjaxCancelled          = -999;
static NSInteger const WPWebViewErrorFrameLoadInterrupted   = 102;

static CGFloat const WPWebViewProgressInitial               = 0.1;
static CGFloat const WPWebViewProgressFinal                 = 1.0;

static CGFloat const WPWebViewToolbarShownConstant          = 0.0;
static CGFloat const WPWebViewToolbarHiddenConstant         = -44.0;

static CGFloat const WPWebViewAnimationShortDuration        = 0.1;
static CGFloat const WPWebViewAnimationLongDuration         = 0.4;
static CGFloat const WPWebViewAnimationAlphaVisible         = 1.0;
static CGFloat const WPWebViewAnimationAlphaHidden          = 0.0;

static NSString *const WPComReferrerURL = @"https://wordpress.com";

static NSString *const WPWebViewWebKitErrorDomain = @"WebKitErrorDomain";
static NSInteger const WPWebViewErrorPluginHandledLoad = 204;

#pragma mark - Private Properties

@interface WPWebViewController () <UIWebViewDelegate>

@property (nonatomic,   weak) IBOutlet UIWebView                *webView;
@property (nonatomic,   weak) IBOutlet UIProgressView           *progressView;
@property (nonatomic, strong) UIBarButtonItem          *dismissButton;
@property (nonatomic, strong) UIBarButtonItem          *optionsButton;

@property (nonatomic,   weak) IBOutlet UIToolbar                *toolbar;
@property (nonatomic,   weak) IBOutlet UIBarButtonItem          *backButton;
@property (nonatomic,   weak) IBOutlet UIBarButtonItem          *forwardButton;
@property (nonatomic,   weak) IBOutlet NSLayoutConstraint       *toolbarBottomConstraint;

@property (nonatomic, strong) NavigationTitleView               *titleView;
@property (nonatomic, assign) BOOL                              loading;
@property (nonatomic, assign) BOOL                              needsLogin;

@end


#pragma mark - WPWebViewController

@implementation WPWebViewController

- (void)dealloc
{
    _webView.delegate = nil;
    if (_webView.isLoading) {
        [_webView stopLoading];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    NSAssert(_webView,                 @"Missing Outlet!");
    NSAssert(_progressView,            @"Missing Outlet!");

    NSAssert(_toolbar,                 @"Missing Outlet!");
    NSAssert(_backButton,              @"Missing Outlet!");
    NSAssert(_forwardButton,           @"Missing Outlet!");
    NSAssert(_toolbarBottomConstraint, @"Missing Outlet!");
    
    // TitleView
    self.titleView                          = [NavigationTitleView new];
    self.titleView.titleLabel.text          = NSLocalizedString(@"Loading...", @"Loading. Verb");
    self.titleView.subtitleLabel.text       = self.url.host;
    self.navigationItem.titleView           = self.titleView;
    
    // Buttons
    if (!self.optionsButton) {
        self.optionsButton = [[UIBarButtonItem alloc] initWithImage:[Gridicon iconOfType:GridiconTypeShareIOS] style:UIBarButtonItemStylePlain target:self action:@selector(showLinkOptions)];

        self.optionsButton.accessibilityLabel   = NSLocalizedString(@"Share",   @"Spoken accessibility label");
    }

    self.dismissButton = [[UIBarButtonItem alloc] initWithImage:[Gridicon iconOfType:GridiconTypeCross] style:UIBarButtonItemStylePlain target:self action:@selector(dismiss)];

    self.dismissButton.accessibilityLabel   = NSLocalizedString(@"Dismiss", @"Dismiss a view. Verb");
    self.backButton.accessibilityLabel      = NSLocalizedString(@"Back",    @"Previous web page");
    self.forwardButton.accessibilityLabel   = NSLocalizedString(@"Forward", @"Next web page");
    
    self.backButton.image                   = [[Gridicon iconOfType:GridiconTypeChevronLeft] imageFlippedForRightToLeftLayoutDirection];
    self.forwardButton.image                = [[Gridicon iconOfType:GridiconTypeChevronRight] imageFlippedForRightToLeftLayoutDirection];

    // Toolbar: Hidden by default!
    self.toolbar.barTintColor               = [UIColor whiteColor];
    self.backButton.tintColor               = [WPStyleGuide greyLighten10];
    self.forwardButton.tintColor            = [WPStyleGuide greyLighten10];
    self.toolbarBottomConstraint.constant   = WPWebViewToolbarHiddenConstant;
    
    // WebView
    self.webView.scalesPageToFit            = YES;
    
    // Share
    if (!self.secureInteraction) {
        self.navigationItem.rightBarButtonItem  = self.optionsButton;
    }

    // Fire away!
    [self applyModalStyleIfNeeded];
    [self loadWebViewRequest];
}

- (void)applyModalStyleIfNeeded
{
    // Proceed only if this Modal, and it's the only view in the stack.
    // We're not changing the NavigationBar style, if we're sharing it with someone else!
    if (self.presentingViewController == nil || self.navigationController.viewControllers.count > 1) {
        return;
    }
    
    UIImage *navBackgroundImage             = [UIImage imageWithColor:[WPStyleGuide webViewModalNavigationBarBackground]];
    UIImage *navShadowImage                 = [UIImage imageWithColor:[WPStyleGuide webViewModalNavigationBarShadow]];
    
    UINavigationBar *navigationBar          = self.navigationController.navigationBar;
    navigationBar.shadowImage               = navShadowImage;
    navigationBar.barStyle                  = UIBarStyleDefault;
    [navigationBar setBackgroundImage:navBackgroundImage forBarMetrics:UIBarMetricsDefault];
    
    self.titleView.titleLabel.textColor     = [WPStyleGuide darkGrey];
    self.titleView.subtitleLabel.textColor  = [WPStyleGuide grey];
    
    self.dismissButton.tintColor            = [WPStyleGuide greyLighten10];
    self.optionsButton.tintColor            = [WPStyleGuide greyLighten10];
    
    self.progressView.progressTintColor     = [WPStyleGuide lightBlue];
    
    self.navigationItem.leftBarButtonItem   = self.dismissButton;
}

- (BOOL)hidesBottomBarWhenPushed
{
    return YES;
}

- (BOOL)expectsWidePanel
{
    return YES;
}


#pragma mark - Document Helpers

- (NSString *)documentPermalink
{
    NSString *permaLink = self.webView.request.URL.absoluteString;

    // Make sure we are not sharing URL like this: http://en.wordpress.com/reader/mobile/?v=post-16841252-1828
    if ([permaLink rangeOfString:@"wordpress.com/reader/mobile/"].location != NSNotFound) {
        permaLink = WPMobileReaderURL;
    }

    return permaLink;
}

- (NSString *)documentTitle
{
    NSString *title = [self.webView stringByEvaluatingJavaScriptFromString:@"document.title"];

    if (title != nil && [[title trim] isEqualToString:@""] == NO) {
        return title;
    }

    return [self documentPermalink] ?: [NSString string];
}


#pragma mark - Helper Methods

- (void)loadWebViewRequest
{
    if (![ReachabilityUtils isInternetReachable]) {
        [self showNoInternetAlertView];
        return;
    }

    BOOL hasCookies = [WPCookie hasCookieForURL:self.url andUsername:self.username];
    if (self.url.isWordPressDotComUrl && !self.needsLogin && self.hasCredentials && !hasCookies) {
        DDLogWarn(@"WordPress.com URL: We have login credentials but no cookie, let's try login first");
        [self retryWithLogin];
        return;
    }
    
    NSURLRequest *request = [self newRequestForWebsite];
    NSAssert(request, @"We should have a valid request here!");
    
    [self.webView loadRequest:request];
}

- (void)retryWithLogin
{
    self.needsLogin = YES;
    [self loadWebViewRequest];
}

- (void)refreshInterface
{
    self.backButton.enabled             = self.webView.canGoBack;
    self.forwardButton.enabled          = self.webView.canGoForward;
    self.optionsButton.enabled          = !self.loading;
    
    if (self.loading) {
        return;
    }
    
    self.titleView.titleLabel.text      = [self documentTitle];
    self.titleView.subtitleLabel.text   = self.webView.request.URL.host;
}

- (void)scrollToBottomIfNeeded
{
    if (!self.shouldScrollToBottom) {
        return;
    }
    
    self.shouldScrollToBottom = NO;
    
    UIScrollView *scrollView    = self.webView.scrollView;
    CGPoint bottomOffset        = CGPointMake(0, scrollView.contentSize.height - scrollView.bounds.size.height);
    [scrollView setContentOffset:bottomOffset animated:YES];
}

- (void)showNoInternetAlertView
{
    __typeof(self) __weak weakSelf = self;
    [ReachabilityUtils showAlertNoInternetConnectionWithRetryBlock:^{
        [weakSelf loadWebViewRequest];
    }];
}

- (void)showBottomToolbarIfNeeded
{
    if (self.secureInteraction) {
        return;
    }

    if (!self.webView.canGoBack && !self.webView.canGoForward) {
        return;
    }
    
    if (self.toolbarBottomConstraint.constant == WPWebViewToolbarShownConstant) {
        return;
    }

    [UIView animateWithDuration:WPWebViewAnimationShortDuration animations:^{
        self.toolbarBottomConstraint.constant = WPWebViewToolbarShownConstant;
        [self.view layoutIfNeeded];
    }];
}


#pragma mark - Properties

- (void)setUrl:(NSURL *)theURL
{
    if (_url == theURL) {
        return;
    }

    // If the URL has no scheme defined, default to http.
    if (![theURL.scheme hasPrefix:@"http"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:theURL resolvingAgainstBaseURL:NO];
        components.scheme = @"http";
        theURL = [components URL];
    }

    _url = theURL;
    
    // Prevent double load in viewDidLoad Method
    if (self.isViewLoaded) {
        [self loadWebViewRequest];
    }
}


#pragma mark - IBAction Methods

- (IBAction)dismiss
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)goBack
{
    [self.webView goBack];
}

- (IBAction)goForward
{
    [self.webView goForward];
}

- (IBAction)showLinkOptions
{
    NSString *permaLink             = [self documentPermalink];
    NSMutableArray *activityItems   = [NSMutableArray array];
    
    [activityItems addObject:[NSURL URLWithString:permaLink]];
    
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:activityItems applicationActivities:[WPActivityDefaults defaultActivities]];
    activityViewController.completionWithItemsHandler = ^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        if (!completed) {
            return;
        }
        [WPActivityDefaults trackActivityType:activityType];
    };

    if ([UIDevice isPad]) {        
        activityViewController.modalPresentationStyle = UIModalPresentationPopover;
        activityViewController.popoverPresentationController.barButtonItem = self.optionsButton;
    }
    
    [self presentViewController:activityViewController animated:YES completion:nil];
}


#pragma mark - UIWebViewDelegate

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    DDLogInfo(@"%@ Should Start Loading [%@]", NSStringFromClass([self class]), request.URL.absoluteString);
    
    // WP Login: Send the credentials, if needed
    NSRange loginRange  = [request.URL.absoluteString rangeOfString:@"wp-login.php"];
    BOOL isLoginURL     = loginRange.location != NSNotFound;
    
    if (isLoginURL && !self.needsLogin && self.hasCredentials) {
        DDLogInfo(@"WP is asking for credentials, let's login first");
        [self retryWithLogin];
        return NO;
    }
    
    // To handle WhatsApp and Telegraph shares
    // Even though the documentation says that canOpenURL will only return YES for
    // URLs configured on the plist under LSApplicationQueriesSchemes if we don't filter
    // out http requests it also returns YES for those
    if (![request.URL.scheme hasPrefix:@"http"]
        && [[UIApplication sharedApplication] canOpenURL:request.URL]) {
        [[UIApplication sharedApplication] openURL:request.URL
                                           options:nil
                                 completionHandler:nil];
        return NO;
    }

    //  Note:
    //  UIWebView callbacks will get hit for every frame that gets loaded. As a workaround, we'll consider
    //  we're in a "loading" state just for the Top Level request.
    //
    if ([request.mainDocumentURL isEqual:request.URL]) {
        self.loading = YES;
        [self refreshInterface];
    }
    
    return YES;
}

- (void)webViewDidStartLoad:(UIWebView *)aWebView
{
    DDLogInfo(@"%@ Started Loading [%@]", NSStringFromClass([self class]), aWebView.request.URL);
    
    // Bypass if we're not loading the "Main Document"
    if (!self.loading) {
        return;
    }
    
    [self startProgress];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    DDLogInfo(@"%@ Error Loading [%@]", NSStringFromClass([self class]), error);
    
    // Bypass if we're not loading the "Main Document"
    if (!self.loading) {
        return;
    }
    
    // Refresh the Interface
    self.loading = NO;
    
    [self finishProgress];
    [self refreshInterface];

    // Don't show Ajax Cancelled or Frame Load Interrupted errors
    if (error.code == WPWebViewErrorAjaxCancelled || error.code == WPWebViewErrorFrameLoadInterrupted) {
        return;
    } else if ([error.domain isEqualToString:WPWebViewWebKitErrorDomain] && error.code == WPWebViewErrorPluginHandledLoad) {
        return;
    }

    [self displayLoadError:error];
}

- (void)displayLoadError:(NSError *)error
{
    [WPError showAlertWithTitle:NSLocalizedString(@"Error", nil) message:error.localizedDescription];
}

- (void)webViewDidFinishLoad:(UIWebView *)aWebView
{
    DDLogInfo(@"%@ Finished Loading [%@]", NSStringFromClass([self class]), aWebView.request.URL);
    
    // Bypass if we're not loading the "Main Document"
    if (!self.loading) {
        return;
    }
    
    self.loading = NO;
    
    [self finishProgress];
    [self refreshInterface];
    [self showBottomToolbarIfNeeded];
    [self scrollToBottomIfNeeded];
}


#pragma mark - Progress Bar Helpers

- (void)startProgress
{
    self.progressView.alpha     = WPWebViewAnimationAlphaVisible;
    self.progressView.progress  = WPWebViewProgressInitial;
}

- (void)finishProgress
{
    [UIView animateWithDuration:WPWebViewAnimationLongDuration animations:^{
        self.progressView.progress = WPWebViewProgressFinal;
    } completion:^(BOOL finished) {
       [UIView animateWithDuration:WPWebViewAnimationShortDuration animations:^{
           self.progressView.alpha = WPWebViewAnimationAlphaHidden;
       }];
    }];
}


#pragma mark - Authentication Helpers

- (BOOL)hasCredentials
{
    return self.username && (self.password || self.authToken);
}


#pragma mark - Requests Helpers

- (NSURLRequest *)newRequestForWebsite
{
    NSString *userAgent = [WPUserAgent wordPressUserAgent];
    NSURLRequest *request;
    if (!self.needsLogin) {
        request = [WPURLRequest requestWithURL:self.url userAgent:userAgent];
    } else {
        NSURL *loginURL = self.wpLoginURL ?: [self authUrlFromUrl:self.url];
        request = [WPURLRequest requestForAuthenticationWithURL:loginURL
                                                    redirectURL:self.url
                                                       username:self.username
                                                       password:self.password
                                                    bearerToken:self.authToken
                                                      userAgent:userAgent];
    }

    if (self.addsWPComReferrer) {
        NSMutableURLRequest *mReq = [request isKindOfClass:[NSMutableURLRequest class]] ? (NSMutableURLRequest *)request : [request mutableCopy];
        [mReq setValue:WPComReferrerURL forHTTPHeaderField:@"Referer"];
        request = mReq;
    }

    return request;
}

- (NSURL *)authUrlFromUrl:(NSURL *)url
{
    // Note:
    // WordPress CDN doesn't really deal with Auth. We'll replace `.files.wordpress.com` with `.wordpress`.
    // Don't worry, we'll redirect the user to the pristine URL afterwards. Issue #4983
    //
    NSURLComponents *components = [NSURLComponents new];
    components.scheme           = url.scheme;
    components.host             = [url.host stringByReplacingOccurrencesOfString:@".files.wordpress.com"
                                                                      withString:@".wordpress.com"];
    components.path             = @"/wp-login.php";

    return components.URL;
}


#pragma mark - Static Helpers

+ (instancetype)webViewControllerWithURL:(NSURL *)url
{
    NSParameterAssert(url);
    
    WPWebViewController *webViewController = [WPWebViewController new];
    webViewController.url = url;
    return webViewController;
}

+ (instancetype)webViewControllerWithURL:(NSURL *)url
                           optionsButton:(UIBarButtonItem *)button
{
    NSParameterAssert(url);

    WPWebViewController *webViewController = [WPWebViewController new];
    webViewController.url = url;
    webViewController.optionsButton = button;
    return webViewController;
}

@end
