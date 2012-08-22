//
//  KeenClient.m
//  KeenClient
//
//  Created by Daniel Kador on 2/8/12.
//  Copyright (c) 2012 Keen Labs. All rights reserved.
//

#import "KeenClient.h"
#import "KeenConstants.h"
#import "KeenJSONSerialization.h"


static KeenClient *sharedClient;

@interface KeenClient ()

// The project ID for this particular client.
@property (nonatomic, retain) NSString *projectId;

// The authorization token for this particular project.
@property (nonatomic, retain) NSString *token;

// How many times the previous timestamp has been used.
@property (nonatomic) NSInteger numTimesTimestampUsed;

// The max number of events per collection.
@property (nonatomic, readonly) NSUInteger maxEventsPerCollection;

// The number of events to drop when aging out a collection.
@property (nonatomic, readonly) NSUInteger numberEventsToForget;

// If we're running tests.
@property (nonatomic) Boolean isRunningTests;

/**
 Initializes KeenClient without setting its project ID or auth token.
 @returns An instance of KeenClient.
 */
- (id)init;

/**
 Validates that the given project ID and authorization token are valid.
 @param projectId The Keen project ID.
 @param authToken The Keen auth token.
 @returns YES if project ID and auth token are valid, NO otherwise.
 */
+ (BOOL)validateProjectId:(NSString *)projectId andAuthToken:(NSString *)authToken;

/**
 Returns the path to the app's library/cache directory.
 @returns An NSString* that is a path to the app's documents directory.
 */
- (NSString *)cacheDirectory;

/**
 Returns the root keen directory where collection sub-directories exist.
 @returns An NSString* that is a path to the keen root directory.
 */
- (NSString *)keenDirectory;

/**
 Returns the direct child sub-directories of the root keen directory.
 @returns An NSArray* of NSStrings* that are names of sub-directories.
 */
- (NSArray *)keenSubDirectories;

/**
 Returns all the files and directories that are children of the argument path.
 @param path An NSString* that's a fully qualified path to a directory on the file system.
 @returns An NSArray* of NSStrings* that are names of sub-files or directories.
 */
- (NSArray *)contentsAtPath:(NSString *)path;

/**
 Returns the directory for a particular collection where events exist.
 @param collection The collection.
 @returns An NSString* that is a path to the collection directory.
 */
- (NSString *)eventDirectoryForCollection:(NSString *)collection;

/**
 Returns the full path to write an event to.
 @param collection The collection name.
 @param timestamp  The timestamp of the event.
 @returns An NSString* that is a path to the event to be written.
 */
- (NSString *)pathForEventInCollection:(NSString *)collection 
                         WithTimestamp:(NSDate *)timestamp;

/**
 Creates a directory if it doesn't exist.
 @param dirPath The fully qualfieid path to a directory.
 @returns YES if the directory exists at the end of this operation, NO otherwise.
 */
- (BOOL)createDirectoryIfItDoesNotExist:(NSString *)dirPath;

/**
 Writes a particular blob to the given file.
 @param data The data blob to write.
 @param file The fully qualified path to a file.
 @returns YES if the file was successfully written, NO otherwise.
 */
- (BOOL)writeNSData:(NSData *)data 
             toFile:(NSString *)file;

/**
 Sends an event to the server. Internal impl.
 @param data The data to send.
 @param response The response being returned.
 @param error If an error occurred, filled in.  Otherwise nil.
 */
- (NSData *)sendEvents:(NSData *)data 
     returningResponse:(NSURLResponse **)response 
                 error:(NSError **)error;

/**
 Harvests local file system for any events to send to keen service and prepares the payload
 for the API request.
 @param jsonData If successful, this will be filled with the correct JSON data.  Otherwise it is untouched.
 @param eventPaths If successful, this will be filled with a dictionary that maps event types to their paths on the local filesystem.
 */
- (void)prepareJSONData:(NSData **)jsonData 
          andEventPaths:(NSMutableDictionary **)eventPaths;

/**
 Handles the HTTP response from the keen API.  This involves deserializing the JSON response
 and then removing any events from the local filesystem that have been handled by the keen API.
 @param response The response from the server.
 @param responseData The data returned from the server.
 @param eventPaths A dictionary that maps events to their paths on the file system.
 */
- (void)handleAPIResponse:(NSURLResponse *)response 
                  andData:(NSData *)responseData 
            forEventPaths:(NSDictionary *)eventPaths;
    
@end

@implementation KeenClient

@synthesize projectId=_projectId;
@synthesize token=_token;
@synthesize numTimesTimestampUsed=_numTimesTimestampUsed;
@synthesize isRunningTests=_isRunningTests;

# pragma mark - Class lifecycle

+ (void)initialize {
    // initialize the dictionary used to cache clients exactly once.
    
    if (self != [KeenClient class]) {
        /*
         Without this extra check, your initializations could run twice if you ever have a subclass that
         doesn't implement its own +initialize method. This is not just a theoretical concern, even if
         you don't write any subclasses. Apple's Key-Value Observing creates dynamic subclasses which
         don't override +initialize.
         */
        return;
    }
    
    if (!sharedClient) {
        sharedClient = [[KeenClient alloc] init];
    }
}

- (id)init {
    self = [super init];
    return self;
}

+ (BOOL)validateProjectId:(NSString *)projectId andAuthToken:(NSString *)authToken {
    // validate that project id and auth token are acceptable
    if (!projectId || !authToken || [projectId length] == 0 || [authToken length] == 0) {
        return NO;
    }
    return YES;
}

- (id)initWithProjectId:(NSString *)projectId andAuthToken:(NSString *)authToken {
    if (![KeenClient validateProjectId:projectId andAuthToken:authToken]) {
        return nil;
    }
    
    self = [super init];
    if (self) {
        KCLog(@"Called init on KeenClient for token: %@", authToken);
        self.projectId = projectId;
        self.token = authToken;
    }
    
    return self;
}

- (void)dealloc {
    self.projectId = nil;
    self.token = nil;
    [super dealloc];
}

# pragma mark - Get a shared client

+ (KeenClient *)sharedClientWithProjectId:(NSString *)projectId andAuthToken:(NSString *)authToken {
    if (![KeenClient validateProjectId:projectId andAuthToken:authToken]) {
        return nil;
    }
    sharedClient.projectId = projectId;
    sharedClient.token = authToken;
    return sharedClient;
}

+ (KeenClient *)sharedClient {
    if (![KeenClient validateProjectId:sharedClient.projectId andAuthToken:sharedClient.token]) {
        KCLog(@"sharedClient requested before registering project ID and authorization token!");
        return nil;
    }
    return sharedClient;
}

# pragma mark - Add events

- (BOOL)addEvent:(NSDictionary *)event toCollection:(NSString *)collection {
    return [self addEvent:event withHeaderProperties:nil toCollection:collection];
}

- (BOOL)addEvent:(NSDictionary *)event withHeaderProperties:(NSDictionary *)headerProperties toCollection:(NSString *)collection {
    // don't do anything if event or collection are nil.
    if (!event || !collection) {
        KCLog(@"Invalid event or collection sent to addEvent.");
        return NO;
    }
    KCLog(@"Adding event to collection: %@", collection);
    
    // make sure the directory we want to write the file to exists
    NSString *dirPath = [self eventDirectoryForCollection:collection];
    // if the directory doesn't exist, create it.
    Boolean success = [self createDirectoryIfItDoesNotExist:dirPath];
    if (!success) {
        KCLog(@"Couldn't create directory at path %@", dirPath);
        return NO;
    }
    // now make sure that we haven't hit the max number of events in this collection already
    NSArray *eventsArray = [self contentsAtPath:dirPath];
    if ([eventsArray count] >= self.maxEventsPerCollection) {
        // need to age out old data so the cache doesn't grow too large
        KCLog(@"Too many events in cache for %@, aging out old data.", collection);
        KCLog(@"Count: %d and Max: %d", [eventsArray count], self.maxEventsPerCollection);
        
        NSArray *sortedEventsArray = [eventsArray sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        // delete the eldest
        for (int i=0; i<self.numberEventsToForget; i++) {
            NSString *fileName = [sortedEventsArray objectAtIndex:i];
            NSString *fullPath = [dirPath stringByAppendingPathComponent:fileName];
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtPath:fullPath error:&error];
            if (error) {
                KCLog(@"Couldn't delete %@ when aging events out of cache!", [error localizedDescription]);
            }
        }
    }
    
    NSDictionary *headerPropertiesToWrite = nil;
    NSDate *timestamp = [NSDate date];
    
    if (!headerProperties) {
        headerPropertiesToWrite = [NSDictionary dictionaryWithObject:timestamp forKey:@"timestamp"];
    } else {
        // if there's no timestamp in the system properties, stamp it automatically.
        NSDate *providedTimestamp = [headerProperties objectForKey:@"timestamp"];
        if (!providedTimestamp) {
            NSMutableDictionary *mutableHeaderProperties = [NSMutableDictionary dictionaryWithDictionary:headerProperties];
            [mutableHeaderProperties setValue:timestamp forKey:@"timestamp"];
            headerPropertiesToWrite = mutableHeaderProperties;
        } else {
            headerPropertiesToWrite = headerProperties;
            KCLog(@"Timestamp provided: %@", providedTimestamp);
        }
    }
    
    NSDictionary *eventToWrite = [NSDictionary dictionaryWithObjectsAndKeys:headerPropertiesToWrite, @"header", 
                                  event, @"body", nil];
    
    NSError *error = nil;
    NSData *jsonData = nil;
    @try {
        jsonData = [KeenJSONSerialization dataWithJSONObject:eventToWrite options:0 error:&error];
    }
    @catch (NSException *e) {
//        KCLog(@"An error occurred when serializing event to JSON: %@", [error localizedDescription]);
        return NO;
    }
    
    // now figure out the correct filename.
    NSString *fileName = [self pathForEventInCollection:collection WithTimestamp:timestamp];
    
    // write JSON to file system
    return [self writeNSData:jsonData toFile:fileName];
}

# pragma mark - Uploading

- (void)uploadHelperWithFinishedBlock:(void (^)()) block {
    // only one thread should be doing an upload at a time.
    @synchronized(self) {        
        // get data for the API request we'll make
        NSData *data = nil;
        NSMutableDictionary *eventPaths = nil;
        [self prepareJSONData:&data andEventPaths:&eventPaths];
        if (!data || !eventPaths) {
            return;
        }
        
        // then make an http request to the keen server.
        NSURLResponse *response = nil;
        NSError *error = nil;
        NSData *responseData = [self sendEvents:data returningResponse:&response error:&error];
        
        // then parse the http response and deal with it appropriately
        [self handleAPIResponse:response andData:responseData forEventPaths:eventPaths];
        
        // finally, run the user-specific block (if there is one)
        if (block) {
            KCLog(@"Running user-specified block.");
            @try {
                block();
            } @finally {
                Block_release(block);
            }
        }
    }
}

- (void)uploadWithFinishedBlock:(void (^)()) block {
    id copiedBlock = Block_copy(block);
    if (self.isRunningTests) {
        // run upload in same thread if we're in tests
        [self uploadHelperWithFinishedBlock:copiedBlock];
    } else {
        // otherwise do it in the background to not interfere with UI operations
        [self performSelectorInBackground:@selector(uploadHelperWithFinishedBlock:) withObject:copiedBlock];
    }
}

- (void)prepareJSONData:(NSData **)jsonData andEventPaths:(NSMutableDictionary **)eventPaths {
    // list all the directories under Keen
    NSArray *directories = [self keenSubDirectories];
    NSString *rootPath = [self keenDirectory];
    
    // set up the request dictionary we'll send out.
    NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
    
    // declare an error object
    NSError *error = nil;
    
    // create a structure that will hold corresponding paths to all the files
    NSMutableDictionary *fileDict = [NSMutableDictionary dictionary];
    
    // iterate through each directory
    for (NSString *dirName in directories) {
        KCLog(@"Found directory: %@", dirName);
        // list contents of each directory
        NSString *dirPath = [rootPath stringByAppendingPathComponent:dirName];
        NSArray *files = [self contentsAtPath:dirPath];
        
        // set up the array of events that will be used in the request
        NSMutableArray *requestArray = [NSMutableArray array];
        // set up the array of file paths
        NSMutableArray *fileArray = [NSMutableArray array];
        
        for (NSString *fileName in files) {
            KCLog(@"Found file: %@/%@", dirName, fileName);
            NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
            // for each file, grab the JSON blob
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            // deserialize it
            error = nil;
            NSDictionary *eventDict = [KeenJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (error) {
                KCLog(@"An error occurred when deserializing a saved event: %@", [error localizedDescription]);
                continue;
            }
            // and then add it to the array of events
            [requestArray addObject:eventDict];
            // and also to the array of paths
            [fileArray addObject:filePath];
        }
        // and then add the array back to the overall request
        [requestDict setObject:requestArray forKey:dirName];
        // and also to the dictionary of paths
        [fileDict setObject:fileArray forKey:dirName];
    }
    
    // end early if there are no events
    if ([requestDict count] == 0) {
        KCLog(@"Upload called when no events were present, ending early.");
        return;
    }
    
    // now take the request dict and serialize it to JSON
    
    // first serialize the request dict back to a json string
    error = nil;
    NSData *data = nil;
    @try {
        data = [KeenJSONSerialization dataWithJSONObject:requestDict options:0 error:&error];
    }
    @catch (NSException *e) {
//        KCLog(@"An error occurred when serializing the final request data back to JSON: %@", 
//              [error localizedDescription]);
        // can't do much here.
        return;
    }
    
    *jsonData = data;
    *eventPaths = fileDict;
}

- (void)handleAPIResponse:(NSURLResponse *)response 
                  andData:(NSData *)responseData 
            forEventPaths:(NSDictionary *)eventPaths {
    if (!responseData) {
        KCLog(@"responseData was nil for some reason.  That's not great.");
        KCLog(@"response status code: %d", [((NSHTTPURLResponse *) response) statusCode]);
        return;
    }
    
    NSInteger responseCode = [((NSHTTPURLResponse *)response) statusCode];
    // if the request succeeded, dig into the response to figure out which events succeeded and which failed
    if (responseCode == 200) {
        // deserialize the response
        NSError *error = nil;
        NSDictionary *responseDict = [KeenJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
        if (error) {
            NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            KCLog(@"An error occurred when deserializing HTTP response JSON into dictionary.\nError: %@\nResponse: %@", [error localizedDescription], responseString);
            [responseString release];
            return;
        }
        // now iterate through the keys of the response, which represent collection names
        NSArray *collectionNames = [responseDict allKeys];
        for (NSString *collectionName in collectionNames) {
            // grab the results for this collection
            NSArray *results = [responseDict objectForKey:collectionName];
            // go through and delete any successes and failures because of user error
            // (making sure to keep any failures due to server error)
            NSUInteger count = 0;
            for (NSDictionary *result in results) {
                Boolean deleteFile = YES;
                Boolean success = [[result objectForKey:kKeenSuccessParam] boolValue];
                if (!success) {
                    // grab error code and description
                    NSDictionary *errorDict = [result objectForKey:kKeenErrorParam];
                    NSString *errorCode = [errorDict objectForKey:kKeenNameParam];
                    if ([errorCode isEqualToString:kKeenInvalidCollectionNameError] ||
                        [errorCode isEqualToString:kKeenInvalidPropertyNameError] ||
                        [errorCode isEqualToString:kKeenInvalidPropertyValueError]) {
                        KCLog(@"An invalid event was found.  Deleting it.  Error: %@", 
                              [errorDict objectForKey:kKeenDescriptionParam]);
                        deleteFile = YES;
                    } else {
                        KCLog(@"The event could not be inserted for some reason.  Error name and description: %@, %@", 
                              errorCode, [errorDict objectForKey:kKeenDescriptionParam]);
                        deleteFile = NO;
                    }
                }
                // delete the file if we need to
                if (deleteFile) {
                    NSString *path = [[eventPaths objectForKey:collectionName] objectAtIndex:count];
                    error = nil;
                    
                    // get a file manager
                    NSFileManager *fileManager = [NSFileManager defaultManager];
                    
                    [fileManager removeItemAtPath:path error:&error];
                    if (error) {
                        KCLog(@"CRITICAL ERROR: Could not remove event at %@ because: %@", path, 
                              [error localizedDescription]);
                    } else {
                        KCLog(@"Successfully deleted file: %@", path);
                    }
                }
                count++;
            }
        }
    } else {
        // response code was NOT 200, which means something else happened. log this.
        KCLog(@"Response code was NOT 200. It was: %d", responseCode);
        NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        KCLog(@"Response body was: %@", responseString);
        [responseString release];
    }            
}

# pragma mark - HTTP request/response management

- (NSData *)sendEvents:(NSData *)data returningResponse:(NSURLResponse **)response error:(NSError **)error {
    NSString *urlString = [NSString stringWithFormat:@"%@/%@/projects/%@/_events", 
                           kKeenServerAddress, kKeenApiVersion, self.projectId];
    KCLog(@"Sending request to: %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.token forHTTPHeaderField:@"Authorization"];
    // TODO check if setHTTPBody also sets content-length
    [request setValue:[NSString stringWithFormat:@"%d", [data length]] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:data];
    NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:response error:error];
    return responseData;
}

# pragma mark - Directory/path management

- (NSString *)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return documentsDirectory;
}

- (NSString *)keenDirectory {
    NSString *keenDirPath = [[self cacheDirectory] stringByAppendingPathComponent:@"keen"];
    return [keenDirPath stringByAppendingPathComponent:self.projectId];
}

- (NSArray *)keenSubDirectories {
    return [self contentsAtPath:[self keenDirectory]];
}

- (NSArray *)contentsAtPath:(NSString *) path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        KCLog(@"An error occurred when listing directory (%@) contents: %@", path, [error localizedDescription]);
        return nil;
    }
    return files;
}

- (NSString *)eventDirectoryForCollection:(NSString *)collection {
    return [[self keenDirectory] stringByAppendingPathComponent:collection];
}

- (NSString *)pathForEventInCollection:(NSString *)collection WithTimestamp:(NSDate *)timestamp {
    // get a file manager.
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // determine the root of the filename.
    NSString *name = [NSString stringWithFormat:@"%d", (int)[timestamp timeIntervalSince1970]];
    // get the path to the directory where the file will be written
    NSString *directory = [self eventDirectoryForCollection:collection];
    // start a counter that we'll use to make sure that even if multiple events are written with the same timestamp,
    // we'll be able to handle it.
    uint count = 0;
    
    // declare a tiny helper block to get the next path based on the counter.
    NSString * (^getNextPath)(uint count) = ^(uint count) {
        return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%i", name, count]];
    };
    
    // starting with our root filename.0, see if a file exists.  if it doesn't, great.  but if it does, then go
    // on to filename.1, filename.2, etc.
    NSString *path = getNextPath(count);
    while ([fileManager fileExistsAtPath:path]) {
        count++;
        path = getNextPath(count);
    }    
    
    return path;
}

- (BOOL)createDirectoryIfItDoesNotExist:(NSString *)dirPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // if the directory doesn't exist, create it.
    if (![fileManager fileExistsAtPath:dirPath]) {
        NSError *error = nil;
        Boolean success = [fileManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            KCLog(@"An error occurred when creating directory (%@). Message: %@", dirPath, [error localizedDescription]);
            return NO;
        } else if (!success) {
            KCLog(@"Failed to create directory (%@) but no error was returned.", dirPath);
            return NO;
        }        
    }
    return YES;
}

- (BOOL)writeNSData:(NSData *)data toFile:(NSString *)file {
    // write file atomically so we don't ever have a partial event to worry about.    
    Boolean success = [data writeToFile:file atomically:YES];
    if (!success) {
        KCLog(@"Error when writing event to file: %@", file);
        return NO;
    } else {
        KCLog(@"Successfully wrote event to file: %@", file);
    }
    return YES;
}

# pragma mark - To make testing easier

- (NSUInteger)maxEventsPerCollection {
    if (self.isRunningTests) {
        return 5;
    }
    return kKeenMaxEventsPerCollection;
}

- (NSUInteger)numberEventsToForget {
    if (self.isRunningTests) {
        return 2;
    }
    return kKeenNumberEventsToForget;
}

@end
