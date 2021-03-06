//  ForumTableViewDataSource.swift
//
//  Copyright 2015 Awful Contributors. CC BY-NC-SA 3.0 US https://github.com/Awful/Awful.app

import AwfulCore
import CoreData
import UIKit

final class ForumTableViewDataSource: NSObject, UITableViewDataSource, FetchedDataManagerDelegate {
    fileprivate let tableView: UITableView
    fileprivate let cellConfigurator: (ForumTableViewCell, Forum, ViewModel) -> Void
    fileprivate let headerThemer: (UITableViewCell) -> Void
    
    fileprivate let favouritesData: FetchedDataManager<ForumMetadata>
    fileprivate let forumsData: FetchedDataManager<Forum>
    fileprivate var observer: CollapseExpandObserver!
    
    fileprivate var models: [Model] = []
    fileprivate(set) var lastFavoriteIndex: Int?
    fileprivate var skipTableUpdate = false
    var isEmpty: Bool {
        return models.isEmpty
    }
    var hasFavorites: Bool {
        return lastFavoriteIndex != nil
    }
    var didReload: (() -> Void)?
    
    init(tableView: UITableView, managedObjectContext: NSManagedObjectContext, cellConfigurator: @escaping (ForumTableViewCell, Forum, ForumTableViewCell.ViewModel) -> Void, headerThemer: @escaping (UITableViewCell) -> Void) {
        self.tableView = tableView
        self.cellConfigurator = cellConfigurator
        self.headerThemer = headerThemer
        
        let fetchFavourites = NSFetchRequest<ForumMetadata>(entityName: ForumMetadata.entityName())
        fetchFavourites.predicate = NSPredicate(format: "favorite == YES")
        fetchFavourites.sortDescriptors = [NSSortDescriptor(key: "favoriteIndex", ascending: true)]
        favouritesData = FetchedDataManager(managedObjectContext: managedObjectContext, fetchRequest: fetchFavourites)
        
        let fetchForums = NSFetchRequest<Forum>(entityName: Forum.entityName())
        fetchForums.sortDescriptors = [
            NSSortDescriptor(key: "group.index", ascending: true),
            NSSortDescriptor(key: "index", ascending: true)
        ]
        forumsData = FetchedDataManager(managedObjectContext: managedObjectContext, fetchRequest: fetchForums)
        
        super.init()
        
        observer = CollapseExpandObserver(managedObjectContext: managedObjectContext) { [weak self] in
            self?.reloadModels()
        }
        
        favouritesData.delegate = self
        forumsData.delegate = self
        
        withoutInformingTable {
            reloadModels()
        }
    }
    
    fileprivate func reloadModels() {
        let oldModels = models
        
        models = []
        let favourites = favouritesData.contents
        if !favourites.isEmpty {
            models.append(.header("Favorites"))
            models += favourites[0 ..< favourites.endIndex - 1].map { .favorite(ViewModel(favorite: $0.forum), $0.forum) }
            let last = favourites.last!
            models.append(.favorite(ViewModel(favorite: last.forum, showSeparator: false), last.forum))
        }
        lastFavoriteIndex = models.isEmpty ? nil : models.count - 1
        
        var currentGroup: ForumGroup? = nil
        var lastForumsInGroup: Set<Forum> = []
        for forum in forumsData.contents.reversed() where forum.group != currentGroup {
            lastForumsInGroup.insert(forum)
            currentGroup = forum.group
        }
        
        currentGroup = nil
        for forum in forumsData.contents {
            if let group = forum.group , group != currentGroup,
                let name = group.name
            {
                currentGroup = group
                models.append(.header(name))
            }

            if forum.isVisible {
                models.append(.forum(ViewModel(forum: forum, showSeparator: !lastForumsInGroup.contains(forum)), forum))
            }
        }
        
        guard !skipTableUpdate else { return }
        let delta = oldModels.delta(models)
        guard !delta.isEmpty else { return }
        
        let pathify: (Int) -> IndexPath = { IndexPath(row: $0, section: 0) }
        tableView.beginUpdates()
        let deletions = delta.deletions.map(pathify)
        tableView.deleteRows(at: deletions, with: .fade)
        let insertions = delta.insertions.map(pathify)
        tableView.insertRows(at: insertions, with: .fade)
        let moves = delta.moves.map { (pathify($0), pathify($1)) }
        moves.forEach(tableView.moveRow)
        tableView.endUpdates()
        
        didReload?()
    }
    
    fileprivate func withoutInformingTable(_ block: () -> Void) {
        skipTableUpdate = true
        block()
        skipTableUpdate = false
    }
    
    func objectAtIndexPath(_ indexPath: IndexPath) -> Forum? {
        switch models[indexPath.row] {
        case let .forum(_, forum):
            return forum
            
        case let .favorite(_, forum):
            return forum
            
        case .header:
            return nil
        }
    }
    
    func indexPathForObject(_ object: Forum) -> IndexPath? {
        for (i, model) in models.enumerated() where model.forum == object {
            return IndexPath(row: i, section: 0)
        }
        return nil
    }
    
    static let headerReuseIdentifier = "Header"
    
    // MARK: FetchedDataManagerDelegate
    
    func dataManagerDidChangeContent<Object: NSManagedObject>(_ dataManager: FetchedDataManager<Object>) {
        reloadModels()
    }
    
    // MARK: UITableViewDataSource
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return models.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let model = models[(indexPath as NSIndexPath).row]
        if case let .header(title) = model {
            let cell = tableView.dequeueReusableCell(withIdentifier: ForumTableViewDataSource.headerReuseIdentifier, for: indexPath)
            cell.textLabel?.text = title
            headerThemer(cell)
            return cell
        }
        
        guard let viewModel = model.viewModel else { fatalError("forum model missing view model") }
        guard let forum = model.forum else { fatalError("forum model missing view forum") }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ForumTableViewCell.identifier, for: indexPath) as? ForumTableViewCell else {
            fatalError("wrong cell type for forum")
        }
        cellConfigurator(cell, forum, viewModel)
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard case .favorite = models[indexPath.row] else { return false }
        return true
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        guard case let .favorite(_, forum) = models[indexPath.row] else { fatalError("can't delete a non-favorite") }
        forum.metadata.favorite = false
        try! forum.managedObjectContext!.save()
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        guard case .favorite = models[indexPath.row] else { return false }
        return true
    }
    
    func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to toIndexPath: IndexPath) {
        withoutInformingTable {
            var favorites = favouritesData.contents
            let moved = favorites.remove(at: fromIndexPath.row - 1)
            favorites.insert(moved, at: toIndexPath.row - 1)
            for (i, metadata) in favorites.enumerated() {
                metadata.favoriteIndex = Int32(i)
            }
            try! favorites[0].managedObjectContext?.save()
        }
    }
}

private typealias ViewModel = ForumTableViewCell.ViewModel

private enum Model: Equatable {
    case header(String)
    case forum(ViewModel, AwfulCore.Forum)
    case favorite(ViewModel, AwfulCore.Forum)

    var forum: AwfulCore.Forum? {
        switch self {
        case .header:
            return nil
            
        case let .forum(_, forum):
            return forum
            
        case let .favorite(_, forum):
            return forum
        }
    }
    
    var viewModel: ViewModel? {
        switch self {
        case .header:
            return nil
            
        case let .forum(viewModel, _):
            return viewModel
            
        case let .favorite(viewModel, _):
            return viewModel
        }
    }
}

private func ==(lhs: Model, rhs: Model) -> Bool {
    switch (lhs, rhs) {
    case let (.header(lhsName), .header(rhsName)):
        return lhsName == rhsName
        
    case let (.favorite(lhsForum, _), .favorite(rhsForum, _)):
        return lhsForum == rhsForum
        
    case let (.forum(lhsForum, _), .forum(rhsForum, _)):
        return lhsForum == rhsForum
        
    default:
        return false
    }
}

extension Forum {
    var ancestors: AnySequence<Forum> {
        var current = parentForum
        return AnySequence {
            return AnyIterator {
                let next = current
                current = current?.parentForum
                return next
            }
        }
    }
    
    fileprivate var isVisible: Bool {
        return ancestors.all { $0.metadata.showsChildrenInForumList }
    }
}

extension ForumTableViewCell.ViewModel {
    fileprivate init(forum: Forum, showSeparator: Bool) {
        favorite = forum.metadata.favorite ? .hidden : .off
        name = forum.name ?? ""
        childSubforumCount = forum.childForums.count
        if forum.childForums.count == 0 {
            canExpand = .hidden
        } else {
            canExpand = forum.metadata.showsChildrenInForumList ? .on : .off
        }
        indentationLevel = Array(forum.ancestors).count
        self.showSeparator = showSeparator
    }
    
    fileprivate init(favorite forum: Forum, showSeparator: Bool = true) {
        favorite = .on
        name = forum.name ?? ""
        childSubforumCount = 0
        canExpand = .hidden
        indentationLevel = 0
        self.showSeparator = showSeparator
    }
}

private class CollapseExpandObserver {
    fileprivate let managedObjectContext: NSManagedObjectContext
    fileprivate let changeBlock: () -> Void
    
    init(managedObjectContext: NSManagedObjectContext, changeBlock: @escaping () -> Void) {
        self.managedObjectContext = managedObjectContext
        self.changeBlock = changeBlock
        
        NotificationCenter.default.addObserver(self, selector: #selector(CollapseExpandObserver.objectsDidChange(_:)), name: NSNotification.Name.NSManagedObjectContextObjectsDidChange, object: managedObjectContext)
    }
    
    @objc fileprivate func objectsDidChange(_ notification: Notification) {
        guard let updatedObjects = (notification as NSNotification).userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> else { return }
        guard updatedObjects
            .filter({ $0 is ForumMetadata })
            .map({ $0.changedValuesForCurrentEvent() })
            .any({ $0.keys.contains("showsChildrenInForumList") })
            else { return }
        changeBlock()
    }
}
