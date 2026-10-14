# SQLite is the searchable projection of the durable JSON records and OCR files.
# It can be rebuilt on opening an archive without assigning any new numbers.
function sql!(db, sql, params=())
    result = DBInterface.execute(db,sql,params)
    try
        for _ in result end
    finally
        DBInterface.close!(result)
    end
    return nothing
end

function open_archive_database(root)
    db = SQLite.DB(joinpath(root,"archive.sqlite"))
    try
        sql!(db,"PRAGMA busy_timeout=5000")
        sql!(db,"PRAGMA foreign_keys=ON")
        version = only([Int(r.user_version) for r in DBInterface.execute(db,"PRAGMA user_version")])
        version in (0,1) || throw(ArgumentError("unsupported archive database version $version"))
        SQLite.transaction(db) do
            sql!(db,"""
                CREATE TABLE IF NOT EXISTS documents (
                    number INTEGER PRIMARY KEY, number_label TEXT NOT NULL,
                    title TEXT NOT NULL, sender TEXT NOT NULL, date TEXT NOT NULL,
                    category TEXT NOT NULL, summary TEXT NOT NULL, ocr TEXT NOT NULL,
                    status TEXT NOT NULL, pdf TEXT NOT NULL, pages INTEGER NOT NULL,
                    record_json TEXT NOT NULL)
                """)
            sql!(db,"CREATE INDEX IF NOT EXISTS documents_category_date ON documents(category,date)")
            sql!(db,"CREATE INDEX IF NOT EXISTS documents_date ON documents(date)")
            sql!(db,"""
                CREATE TABLE IF NOT EXISTS sides (
                    document_number INTEGER NOT NULL REFERENCES documents(number) ON DELETE CASCADE,
                    capture_order INTEGER NOT NULL, sheet INTEGER,
                    side TEXT NOT NULL CHECK(side IN ('front','back','unknown')),
                    source TEXT NOT NULL, blank INTEGER NOT NULL CHECK(blank IN (0,1)),
                    pdf_page INTEGER,
                    PRIMARY KEY(document_number,capture_order), UNIQUE(document_number,pdf_page))
                """)
            sql!(db,"""
                CREATE VIRTUAL TABLE IF NOT EXISTS document_search USING fts5(
                    number_label,title,sender,date,category,summary,ocr,
                    content='documents',content_rowid='number',
                    tokenize='unicode61 remove_diacritics 2',prefix='2 3 4')
                """)
            for (event,old,new) in (("INSERT",false,true),("DELETE",true,false),("UPDATE",true,true))
                columns = "number_label,title,sender,date,category,summary,ocr"
                statements = String[]
                old && push!(statements,"INSERT INTO document_search(document_search,rowid,$columns) VALUES ('delete',old.number," * join(("old."*c for c in split(columns,',')),',') * ");")
                new && push!(statements,"INSERT INTO document_search(rowid,$columns) VALUES (new.number," * join(("new."*c for c in split(columns,',')),',') * ");")
                sql!(db,"CREATE TRIGGER IF NOT EXISTS documents_$(lowercase(event)) AFTER $event ON documents BEGIN " * join(statements,' ') * " END")
            end
            sql!(db,"PRAGMA user_version=1")
        end
        return db
    catch
        close(db)
        rethrow()
    end
end

function index_record!(db, root, r)
    ocr = read(joinpath(root,r["text"]),String)
    payload = JSON3.write(r)
    values = (r["number"],document_number(r["number"]),r["title"],r["sender"],r["date"],
        r["category"],r["summary"],ocr,r["status"],r["pdf"],r["pages"],payload)
    SQLite.transaction(db) do
      sql!(db,"""
        INSERT INTO documents(number,number_label,title,sender,date,category,summary,ocr,status,pdf,pages,record_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(number) DO UPDATE SET number_label=excluded.number_label,
            title=excluded.title,sender=excluded.sender,date=excluded.date,
            category=excluded.category,summary=excluded.summary,ocr=excluded.ocr,
            status=excluded.status,pdf=excluded.pdf,pages=excluded.pages,record_json=excluded.record_json
        WHERE documents.record_json != excluded.record_json OR documents.ocr != excluded.ocr
        """,values)
      sql!(db,"DELETE FROM sides WHERE document_number=?",(r["number"],))
      sides = get(r,"sides",[Dict("pdf_page"=>i,"sheet"=>nothing,"side"=>"unknown","source"=>"","blank"=>false) for i in 1:r["pages"]])
      for (i,side) in enumerate(sides)
          sql!(db,"INSERT INTO sides(document_number,capture_order,sheet,side,source,blank,pdf_page) VALUES(?,?,?,?,?,?,?)",
              (r["number"],i,something(side["sheet"],missing),side["side"],side["source"],Int(side["blank"]),something(side["pdf_page"],missing)))
      end
    end
    return nothing
end

function sync_archive_database!(db,root,records)
    SQLite.transaction(db) do
        for r in records
            index_record!(db,root,r)
        end
        committed = Set(r["number"] for r in records)
        indexed = [Int(r.number) for r in DBInterface.execute(db,"SELECT number FROM documents")]
        for n in indexed
            n in committed || sql!(db,"DELETE FROM documents WHERE number=?",(n,))
        end
    end
end

# Quote each user term as an FTS literal. Search operators and SQL printed in
# documents or typed into the search box are never evaluated as instructions.
function archive_search_query(query)
    terms = split(strip(query))
    return join(("\"" * replace(t,"\""=>"\"\"") * "\"*" for t in terms)," AND ")
end

function search_database(db,query; category=nothing,sender=nothing,date_from=nothing,date_to=nothing,
        number=nothing,limit::Integer=100,offset::Integer=0)
    1 <= limit <= 10_000 || throw(ArgumentError("limit must be 1..10000"))
    offset >= 0 || throw(ArgumentError("offset must not be negative"))
    clauses,params = String[],Any[]
    numeric = occursin(r"^\d+$",strip(query)) ? tryparse(Int,strip(query)) : nothing
    matched = !isempty(strip(query)) && numeric === nothing
    from = matched ? "document_search JOIN documents d ON d.number=document_search.rowid" : "documents d"
    if matched
        push!(clauses,"document_search MATCH ?")
        push!(params,archive_search_query(query))
    end
    if numeric !== nothing
        push!(clauses,"d.number = ?"); push!(params,numeric)
    end
    for (column,value) in (("category",category),("sender",sender),("number",number))
        value === nothing && continue
        push!(clauses,"d.$column = ?"); push!(params,value)
    end
    for (operator,value) in ((">=",date_from),("<=",date_to))
        value === nothing && continue
        date = value isa Date ? value : tryparse(Date,String(value))
        date === nothing && throw(ArgumentError("invalid search date"))
        push!(clauses,"d.date != '' AND d.date $operator ?"); push!(params,string(date))
    end
    where = isempty(clauses) ? "" : " WHERE " * join(clauses," AND ")
    order = matched ? "bm25(document_search,0,5,3,0,1,2,1),d.number" : "d.number"
    append!(params,(limit,offset))
    result = DBInterface.execute(db,"SELECT d.record_json FROM $from$where ORDER BY $order LIMIT ? OFFSET ?",params)
    try
        return [JSON3.read(String(r.record_json),Dict{String,Any}) for r in result]
    finally
        DBInterface.close!(result)
    end
end
