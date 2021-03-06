//
//  NibProcessor.m
//  nib2objc
//
//  Created by Adrian on 3/13/09.
//  Adrian Kosmaczewski 2009
//

#import "NibProcessor.h"
#import "Processor.h"
#import "NSString+Nib2ObjcExtensions.h"

@interface NibProcessor ()

- (void)getDictionaryFromNIB;
- (void)parseChildren:(NSDictionary *)dict ofCurrentView:(NSString *)currentView withObjects:(NSDictionary *)objects;
- (NSString *)classAsInstanceNameForObject:(id)obj;

@end


@implementation NibProcessor

@dynamic input;
@synthesize output = _output;
@synthesize codeStyle = _codeStyle;

- (id)init
{
    if (self = [super init])
    {
        self.codeStyle = NibProcessorCodeStyleProperties;
    }
    return self;
}

- (void)dealloc
{
    [_filename release];
    [_output release];
    [_dictionary release];
    [_data release];
    [super dealloc];
}

#pragma mark -
#pragma mark Properties

- (NSString *)input
{
    return _filename;
}

- (void)setInput:(NSString *)newFilename
{
    [_filename release];
    _filename = nil;
    _filename = [newFilename copy];
    [self getDictionaryFromNIB];
}

- (NSString *)inputAsText
{
    return [[[NSString alloc] initWithData:_data encoding:NSUTF8StringEncoding] autorelease];
}

- (NSDictionary *)inputAsDictionary
{
    NSError *errorStr = nil;
    NSPropertyListFormat format;
    NSDictionary *propertyList = [NSPropertyListSerialization propertyListWithData:_data
                                                                           options:NSPropertyListImmutable
                                                                            format:&format
                                                                             error:&errorStr];
    [errorStr release];
    return propertyList;    
}

#pragma mark -
#pragma mark Private methods

- (void)getDictionaryFromNIB
{
    // Build the NSTask that will run the ibtool utility
    NSArray *arguments = [NSArray arrayWithObjects:_filename, @"--objects", 
                          @"--hierarchy", @"--connections", @"--classes", nil];
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    NSFileHandle *readHandle = [pipe fileHandleForReading];
    NSData *temp = nil;

    [_data release];
    _data = [[NSMutableData alloc] init];
    
    [task setLaunchPath:@"/usr/bin/ibtool"];
    [task setArguments:arguments];
    [task setStandardOutput:pipe];
    [task launch];
    
    while ((temp = [readHandle availableData]) && [temp length]) 
    {
        [_data appendData:temp];
    }

    // This dictionary is ready to be parsed, and it contains
    // everything we need from the NIB file.
    _dictionary = [[self inputAsDictionary] retain];
    
    [task release];
}

- (void)process
{
    //    NSDictionary *nibClasses = [dict objectForKey:@"com.apple.ibtool.document.classes"];
    //    NSDictionary *nibConnections = [dict objectForKey:@"com.apple.ibtool.document.connections"];
    NSDictionary *nibObjects = [_dictionary objectForKey:@"com.apple.ibtool.document.objects"];
    NSMutableDictionary *objects = [[NSMutableDictionary alloc] init];
    
    for (NSDictionary *key in nibObjects)
    {
        id object = [nibObjects objectForKey:key];
        NSString *klass = [object objectForKey:@"class"];

        Processor *processor = [Processor processorForClass:klass];
        processor.scaleFactors = _frameScaleFactors;
        
        if (processor == nil)
        {
#ifdef CONFIGURATION_Debug
            // Get notified about classes not yet handled by this utility
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
            [dict setObject:klass forKey:@"// unknown object (yet)"];
            [objects setObject:dict forKey:key];
            [dict release];
#endif
        }
        else
        {
            NSDictionary *dict = [processor processObject:object];
            [objects setObject:dict forKey:key];
        }
    }
    
    // Let's print everything as source code
    [_output release];
    _output = [[NSMutableString alloc] init];
    for (NSString *identifier in objects)
    {
        id object = [objects objectForKey:identifier];
        NSString *identifierKey = [[identifier stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
        
        // First, output any helper functions, ordered alphabetically
        NSArray *orderedKeys = [object keysSortedByValueUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *key in orderedKeys)
        {
            id value = [object objectForKey:key];
            if ([key hasPrefix:@"__helper__"])
            {
                [_output appendString:value];
                [_output appendString:@"\n"];    
            }
        }
        
        // Then, output the constructor
        id klass = [object objectForKey:@"class"];
        id constructor = [object objectForKey:@"constructor"];
        NSString *instanceName = nil;
        if ([self customInstanceNameForObject:object])
        {
            instanceName = [self customInstanceNameForObject:object];
            [_output appendFormat:@"%@ *%@ = %@;\n", klass, instanceName, constructor];
        }
        else
        {
            instanceName = [self classAsInstanceNameForObject:object];
            instanceName = [NSString stringWithFormat:@"%@%@", instanceName, identifierKey];
            [_output appendFormat:@"%@ *%@ = %@;\n", klass, instanceName, constructor];
        }
                
        // Then, output the properties only, ordered alphabetically
        orderedKeys = [[object allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *key in orderedKeys)
        {
            id value = [object objectForKey:key];
            if (![key hasPrefix:@"__method__"] 
                && ![key isEqualToString:@"constructor"]
                && ![key isEqualToString:@"class"]
                && ![key isEqualToString:@"instanceName"]
                && ![key hasPrefix:@"__helper__"])
            {
                switch (self.codeStyle) 
                {
                    case NibProcessorCodeStyleProperties:
                        [_output appendFormat:@"%@.%@ = %@;\n", instanceName, key, value];
                        break;
                        
                    case NibProcessorCodeStyleSetter:
                        [_output appendFormat:@"[%@ set%@:%@];\n", instanceName, [key capitalize], value];
                        break;
                        
                    default:
                        break;
                }
            }
        }

        // Finally, output the method calls, ordered alphabetically
        orderedKeys = [object keysSortedByValueUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *key in orderedKeys)
        {
            id value = [object objectForKey:key];
            if ([key hasPrefix:@"__method__"])
            {
                [_output appendFormat:@"[%@ %@];\n", instanceName, value];
            }
        }
        [_output appendString:@"\n"];    
    }
    
    // Now that the objects are created, recreate the hierarchy of the NIB
    NSArray *nibHierarchy = [_dictionary objectForKey:@"com.apple.ibtool.document.hierarchy"];
    for (NSDictionary *item in nibHierarchy)
    {
        NSString *currentView = [item objectForKey:@"object-id"];
        [self parseChildren:item ofCurrentView:currentView withObjects:objects];
    }
    
    [objects release];
    objects = nil;
}

- (void)parseChildren:(NSDictionary *)dict ofCurrentView:(NSString *)currentView withObjects:(NSDictionary *)objects
{
    NSArray *children = [dict objectForKey:@"children"];
    if (children != nil)
    {
        for (NSDictionary *subitem in children)
        {
            NSString *subview = [subitem objectForKey:@"object-id"];

            id currentViewObject = [objects objectForKey:currentView];
            NSString *instanceName = nil;
            if ([self customInstanceNameForObject:currentViewObject])
            {
                instanceName = [self customInstanceNameForObject:currentViewObject];
            }
            else
            {
                instanceName = [self classAsInstanceNameForObject:currentViewObject];
                instanceName = [NSString stringWithFormat:@"%@%@", instanceName, currentView];
            }
            
            id subViewObject = [objects objectForKey:subview];
            NSString *subInstanceName = nil;
            if ([self customInstanceNameForObject:subViewObject])
            {
                subInstanceName = [self customInstanceNameForObject:subViewObject];
            }
            else
            {
                subInstanceName = [self classAsInstanceNameForObject:subViewObject];
                subInstanceName = [NSString stringWithFormat:@"%@%@", subInstanceName, subview];
            }
            
            [self parseChildren:subitem ofCurrentView:subview withObjects:objects];
            [_output appendFormat:@"[%@ addSubview:%@];\n", instanceName, subInstanceName];
        }
    }
}

- (NSString *)classAsInstanceNameForObject:(id)obj
{
    id klass = [obj objectForKey:@"class"];
    NSString *instanceName = [[klass lowercaseString] substringFromIndex:2];
    return instanceName;
}

- (NSString *)customInstanceNameForObject:(id)obj
{
    return [obj objectForKey:@"instanceName"];
}

@end
