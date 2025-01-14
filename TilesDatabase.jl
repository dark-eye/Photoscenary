module TilesDatabase

    export tailGroupByIndexInsert!, getTailGroupByIndex, copyTilesByIndex, moveOrDeleteTiles, createFilesListTypeDDSandPNG

    using JuliaDB
    using Printf
    using Parsers
    using Distributed
    using ThreadSafeDicts

    include("./Commons.jl")
    include("./ScanDir.jl")

    struct TailCoordinates
        lonDeg::Float64
        latDeg::Float64
        lon::Int64
        lat::Int64
        x::Int
        y::Int
        function TailCoordinates(index::Int)
            (lonDeg,latDeg,lon,lat,x,y) = Commons.coordFromIndex(index)
            return new(lonDeg,latDeg,lon,lat,x,y)
        end
    end


    struct TailData
        path::Union{String,Nothing}
        name::String
        modDate::Float64
        size::Int
        pixelSizeW::Int
        pixelSizeH::Int
        format::Int
    end


    mutable struct TailGroupByIndex
        #dlock::Threads.SpinLock
        index::Int64
        filesFound::Union{Array{TailData},Nothing}
        coordinates::Union{TailCoordinates,Nothing}
        timeLastScan::Float64
        #function TailGroupByIndex() new(Threads.SpinLock(),0,Any[],nothing,0.0) end
        function TailGroupByIndex() new(0,Any[],nothing,0.0) end
    end


    function tailGroupByIndexInsert!(tgi::TailGroupByIndex,index::Int64,tailData::TailData)
        tgi.index = index
        push!(tgi.filesFound,tailData)
        tgi.coordinates = TailCoordinates(index)
        tgi.timeLastScan = time()
    end


    function getTailGroupByIndex(db::IndexedTable,index::Int64)
        records = filter(val -> val[1] == index,db)
        if length(records) > 0
            return records[1][2]
        else
            return nothing
        end
    end


    function getTailGroupByIndex(db::IndexedTable,index::Int64,path::String)
        records = getTailGroupByIndex(db,index)
        if records != nothing
            for record in records.filesFound
                fl = findlast(path,record.path)
                if fl != nothing
                    if fl[1] == 1
                        return record,records.coordinates
                    else
                        return nothing
                    end
                else
                    return nothing
                end
            end
        else
            return nothing
        end
    end


    function copyTilesByIndex(db::IndexedTable,index::Int64,pixelSizeW::Int,aBasePath::String,aFormat::Int)
        # The PathTo not include the file name and the super 2 levels name
        # For example:
        # Base path: /home/abassign
        # index: 1105762
        # Result is: /home/abassign/w120n30/w113n35/1105762.dds
        records = getTailGroupByIndex(db,index)
        fileExt = aFormat == 0 ? ".png" : ".dds"
        if records != nothing
            isSkip = false
            dataFound = nothing
            for record in records.filesFound
                #dump(record)
                if record.pixelSizeW == pixelSizeW && record.format == aFormat && isSkip == false
                    # Create the effective path
                    cfi = Commons.coordFromIndex(index)
                    basePath = normpath(aBasePath * "/" * cfi[7] * "/" * cfi[8]) ## * "/" * string(index) * fileExt
                    if record.path != (basePath * "/" * string(index) * fileExt)
                        if !ispath(basePath) mkpath(basePath) end
                        cp(record.path,basePath * "/" * string(index) * fileExt,force=true)
                        #println("***** copyTilesByIndex 1: (copy) $(record.path) -> $(basePath * "/" * string(index) * fileExt)")
                        isSkip = false
                    else
                        #println("***** copyTilesByIndex 1: (skip) $(record.path) -> $(basePath * "/" * string(index) * fileExt)")
                        isSkip = true
                    end
                    dataFound = (index,record.path,basePath,isSkip)
                end
            end
            if dataFound != nothing
                return dataFound
            else
                return nothing,nothing,nothing,false
            end
        else
            return nothing,nothing,nothing,false
        end
    end


    function moveOrDeleteTiles(index::Int64,pathFromBase::String,format::Int,pathToBase::Union{String,Nothing} = nothing)
        cfi = Commons.coordFromIndex(index)
        fileExt = format == 0 ? ".png" : ".dds"
        fileFromWithPath = normpath(pathFromBase * "/" * cfi[7] * "/" * cfi[8]) * "/" * string(index) * fileExt
        (isCorrect,pixelSizeW,pixelSizeH) = ifelse(format == 1,Commons.getDDSSize(fileFromWithPath),Commons.getPNGSize(fileFromWithPath))
        try
            if isCorrect && pathToBase != nothing
                baseToWithPath = normpath(pathToBase * "/" * string(pixelSizeW) * "/" * cfi[7] * "/" * cfi[8]) # "/" * string(index) * fileExt
                if !ispath(baseToWithPath) mkpath(baseToWithPath) end
                mv(fileFromWithPath,baseToWithPath * "/" * string(index) * fileExt,force=true)
            else
                rm(fileFromWithPath,force=true)
            end
        catch err
            println("moveOrDeleteTiles - Error: $err")
        end
    end


    function countDirError()
        dirsWithErrors::Int = 0
        add(err) = dirsWithErrors += 1
        get() = dirsWithErrors
        () -> (add;get)
    end


    function scanTailGroupByIndex(path)
    end


    using MemPool

    function saveNew(data::IndexedTable, f::AbstractString)
        sz = open(f, "w") do io
            MemPool.serialize(io, MemPool.MMWrap(data))
        end
        # load(f)  # remove this
    end


    ## For the freexe problem https://github.com/JuliaData/JuliaDB.jl/issues/168
    #import JuliaDB.save
    using MemPool

    function JuliaDB.save(data::IndexedTable, f::AbstractString)
        sz = open(f, "w") do io
            MemPool.serialize(io, MemPool.MMWrap(data))
        end
    end


    function createFilesListTypeDDSandPNG(pathSearch::Union{String,Nothing} = nothing, rootPath::Union{String,Nothing} = nothing, pathSave::Union{String,Nothing} = nothing)
        if pathSearch == nothing pathSearch = homedir() end
        if pathSave != nothing && occursin(pathSearch, pathSave) pathSave = nothing end
        if rootPath != nothing && occursin(pathSearch, rootPath) rootPath = nothing end
        rowsNumber = 0
        DDSFileNumber = 0
        PNGFileNumber = 0
        filesSize = 0
        cde = countDirError()
        timeStart = time()
        # Ref. ThreadSafeDict in: https://discourse.julialang.org/t/can-dicts-be-threadsafe/27172
        #                         https://discourse.julialang.org/t/can-dicts-be-threadsafe/27172/7
        ## tilesFiles = ThreadSafeDict{Int64,TailGroupByIndex}()
        tilesFiles = Dict{Int64,TailGroupByIndex}()
        #lockTh = Threads.ReentrantLock()
        for path in (pathSearch,rootPath,pathSave)
            if path != nothing
                println("\nSearch and test the DDS/PNG files in path: $path")
                if ispath(path)
                    for (root, dirs, files) in ScanDir.walkdir(path; onerror = e->(cde.add(e)))
                        if root != tempdir()
                            #@sync begin
                                #Threads.@threads for file in files
                                for file in files
                                    fe = Commons.getFileExtension(file)
                                    if fe != nothing && (uppercase(fe) == ".DDS" || uppercase(fe) == ".PNG")
                                        index = Parsers.tryparse(Int,Commons.getFileName(file))
                                        if index != nothing
                                            cfi = Commons.coordFromIndex(index)
                                            slash = ifelse(Base.Sys.iswindows(),"\\","/")
                                            if uppercase(fe) == ".DDS"
                                                format = 1
                                                fileWithPath = cfi[7] * slash * cfi[8] * slash * string(index) * ".dds"
                                            else
                                                format = 0
                                                fileWithPath = cfi[7] * slash * cfi[8] * slash * string(index) * ".png"
                                            end
                                            jp = joinpath(root, file)
                                            if findlast(fileWithPath,jp) != nothing
                                                (isCorrect,pixelSizeW,pixelSizeH) = ifelse(format == 1,Commons.getDDSSize(jp),Commons.getPNGSize(jp))
                                                if isCorrect
                                                    td = TailData(jp,file,stat(jp).mtime,stat(jp).size,pixelSizeW,pixelSizeH,format)
                                                    if !haskey(tilesFiles,index) tilesFiles[index] = TailGroupByIndex() end
                                                    tailGroupByIndexInsert!(tilesFiles[index],index,td)
                                                    #Threads.lock(lockTh)
                                                    try
                                                        rowsNumber += 1
                                                        format == 1 ? DDSFileNumber += 1 : PNGFileNumber += 1
                                                        filesSize += stat(jp).size
                                                    finally
                                                        #Threads.unlock(lockTh)
                                                    end
                                                else
                                                    if isfile(jp) rm(jp) end
                                                end
                                            end
                                        end
                                    end
                                #end
                            end
                        end
                        ts = @sprintf("Time: %02.1f",time() - timeStart)
                        print("\rExecute update images files, find n. $(rowsNumber) DDS files: $DDSFileNumber PNG files: $PNGFileNumber with size: $(trunc(Int,filesSize/1000000.0)) Mb $ts")
                    end
                else
                    print("\nError: not found the root path: $path")
                end
            end
        end
        println("\nTerm update DDS/PNG list files: find n. $(cde.get()) dir with errors")
        # t = JuliaDB.table(collect(tilesFiles);pkey=1)
        c = collect(tilesFiles)
#@show c
        t = JuliaDB.table(c;pkey=1)
#@show t
        print("\nSave the database start")

        ##saveNew(t, "./test.jlb")
        print("\nSave the database end")
        return t
        #return JuliaDB.table(collect(tilesFiles);pkey=1)
    end

end

