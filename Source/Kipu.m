//
//  Kipu.m
//
//  Copyright (c) 2014 Elvis Nuñez. All rights reserved.
//

#import "Kipu.h"

#import "NSDictionary+ANDYSafeValue.h"
#import "NSManagedObject+HYPPropertyMapper.h"
#import "NSManagedObject+ANDYMapChanges.h"
#import "ANDYDataManager.h"

#define KIPU_DEBUGGING NO
#define KIPU_NSLog if(KIPU_DEBUGGING)NSLog

@interface NSManagedObject (Kipu)

- (void)kipu_processRelationshipsUsingDictionary:(NSDictionary *)objectDict
                                  andParent:(NSManagedObject *)parent;

- (NSManagedObject *)kipu_safeObjectInContext:(NSManagedObjectContext *)context;

- (NSArray *)kipu_relationships;

@end

@implementation Kipu

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
            completion:(void (^)(NSError *error))completion
{
    [self processChanges:changes
         usingEntityName:entityName
               predicate:nil
              completion:completion];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
             predicate:(NSPredicate *)predicate
            completion:(void (^)(NSError *error))completion
{
    [ANDYDataManager performInBackgroundContext:^(NSManagedObjectContext *context) {
        [self processChanges:changes
             usingEntityName:entityName
                   predicate:predicate
                      parent:nil
                   inContext:context
                  completion:completion];
    }];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
                parent:(NSManagedObject *)parent
            completion:(void (^)(NSError *error))completion
{
    [ANDYDataManager performInBackgroundContext:^(NSManagedObjectContext *context) {

        NSManagedObject *safeParent = [parent kipu_safeObjectInContext:context];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K = %@", parent.entity.name, safeParent];

        [self processChanges:changes
             usingEntityName:entityName
                   predicate:predicate
                      parent:safeParent
                   inContext:context
                  completion:completion];
    }];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
             predicate:(NSPredicate *)predicate
                parent:(NSManagedObject *)parent
             inContext:(NSManagedObjectContext *)context
            completion:(void (^)(NSError *error))completion
{
    KIPU_NSLog(@" ");
    KIPU_NSLog(@"==================================");
    KIPU_NSLog(@"processing changes: %@ for %@ with predicate: %@ parent: %@", changes, entityName, predicate, parent);

    [NSManagedObject andy_mapChanges:changes
                      usingPredicate:predicate
                           inContext:context
                       forEntityName:entityName
                            inserted:^(NSDictionary *objectDict) {

                                NSManagedObject *created = [NSEntityDescription insertNewObjectForEntityForName:entityName
                                                                                         inManagedObjectContext:context];

                                [created hyp_fillWithDictionary:objectDict];

                                KIPU_NSLog(@" ");
                                KIPU_NSLog(@"created (%@): %@", entityName, objectDict);
                                KIPU_NSLog(@" ");

                                [created kipu_processRelationshipsUsingDictionary:objectDict andParent:parent];

                            } updated:^(NSDictionary *objectDict, NSManagedObject *object) {

                                [object hyp_fillWithDictionary:objectDict];

                                KIPU_NSLog(@" ");
                                KIPU_NSLog(@"updated (%@): %@", entityName, object);
                                KIPU_NSLog(@" ");

                                [object kipu_processRelationshipsUsingDictionary:objectDict andParent:parent];
                            }];

    KIPU_NSLog(@"finished changes for %@", entityName);
    KIPU_NSLog(@"==================================");
    KIPU_NSLog(@"  ");

    NSError *error = nil;
    [context save:&error];
    if (error) KIPU_NSLog(@"ANDYNetworking (error while saving %@): %@", entityName, [error description]);

    if (completion) completion(error);
}

@end

@implementation NSManagedObject (Kipu)

- (void)kipu_processRelationshipsUsingDictionary:(NSDictionary *)objectDict
                                  andParent:(NSManagedObject *)parent
{
    NSArray *relationships = [self kipu_relationships];

    for (NSRelationshipDescription *relationship in relationships) {
        if (relationship.isToMany) {

            [self kipu_processRelationship:relationship usingDictionary:objectDict andParent:parent];

        } else if (parent) {
            KIPU_NSLog(@"> Setting to-one relationship... (%@)", relationship.name);

            [self setValue:parent forKey:relationship.name];

            KIPU_NSLog(@" ");
        }
    }
}

- (void)kipu_processRelationship:(NSRelationshipDescription *)relationship
            usingDictionary:(NSDictionary *)objectDict
                  andParent:(NSManagedObject *)parent
{
    NSArray *childs = [objectDict andy_valueForKey:relationship.name];
    if (!childs) {
        if (parent && relationship.inverseRelationship.isToMany) {
            if ([parent.entity.name isEqualToString:relationship.destinationEntity.name]) {
                [self addObjectToParent:parent usingRelationship:relationship];
            }
        }
        return;
    }

    KIPU_NSLog(@">> Processing to-many relationships...");

    NSString *childEntityName = relationship.destinationEntity.name;
    NSString *inverseEntityName = relationship.inverseRelationship.name;
    NSPredicate *childPredicate;

    if (relationship.inverseRelationship.isToMany) {
        NSArray *childIDs = [childs valueForKey:@"id"];
        NSString *destinationKey = [NSString stringWithFormat:@"%@ID", [childEntityName lowercaseString]];
        if (childIDs.count == 1) {
            childPredicate = [NSPredicate predicateWithFormat:@"%K = %@", destinationKey, [[childs valueForKey:@"id"] firstObject]];
        } else {
            childPredicate = [NSPredicate predicateWithFormat:@"ANY %K.%K = %@", relationship.name, destinationKey, [childs valueForKey:@"id"]];
        }
    } else {
        childPredicate = [NSPredicate predicateWithFormat:@"%K = %@", inverseEntityName, self];
    }

    [Kipu processChanges:childs
         usingEntityName:childEntityName
               predicate:childPredicate
                  parent:self
               inContext:self.managedObjectContext
              completion:^(NSError *error) {
                  KIPU_NSLog(@">> Finished to-many relationships...");
                  KIPU_NSLog(@" ");
              }];
}

- (void)addObjectToParent:(NSManagedObject *)parent
        usingRelationship:(NSRelationshipDescription *)relationship
{
    KIPU_NSLog(@">> Setting up to-many relationships...");

    [self willAccessValueForKey:relationship.name];
    NSMutableSet *relatedObjects = [self mutableSetValueForKey:relationship.name];
    [self didAccessValueForKey:relationship.name];
    [relatedObjects addObject:parent];

    [self willChangeValueForKey:relationship.name
                withSetMutation:NSKeyValueSetSetMutation
                   usingObjects:relatedObjects];
    [self setValue:relatedObjects forKey:relationship.name];
    [self didChangeValueForKey:relationship.name
               withSetMutation:NSKeyValueSetSetMutation
                  usingObjects:relatedObjects];

    KIPU_NSLog(@"%@", [self valueForKey:relationship.name]);

    KIPU_NSLog(@">> Finished Setting up to-many relationships...");
    KIPU_NSLog(@" ");
}

- (NSString *)kipu_localKey
{
    return [NSString stringWithFormat:@"%@ID", [self.entity.name lowercaseString]];
}

- (id)kipu_localKeyValue
{
    return [self valueForKey:[self kipu_localKey]];
}

- (NSManagedObject *)kipu_safeObjectInContext:(NSManagedObjectContext *)context
{
    NSError *error = nil;
    NSString *entityName = self.entity.name;
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:entityName];
    NSString *localKey = [NSString stringWithFormat:@"%@ID", [entityName lowercaseString]];
    request.predicate = [NSPredicate predicateWithFormat:@"%K = %@", localKey, [self valueForKey:localKey]];
    NSArray *objects = [context executeFetchRequest:request error:&error];
    if (error) KIPU_NSLog(@"parentError: %@", error);
    if (objects.count != 1) abort();
    return [objects firstObject];
}

- (NSArray *)kipu_relationships
{
    NSMutableArray *relationships = [NSMutableArray array];

    for (id propertyDescription in [self.entity properties]) {

        if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            [relationships addObject:propertyDescription];
        }
    }

    return relationships;
}

@end
