
module util;

import std.conv : to;

import
    repl;

extern(C) void* gc_getProxy();

/**
* The DLL replaces the runtime _d_newclass in order to intercept
* class allocations, and redirect the classes to point at copies
* of the vtables on the heap. This function is called from within
* the DLL for each new class allocation.
*/
extern(C) void hookNewClass(TypeInfo_Class ti, void* cptr, ReplContext* repl, bool clear = false)
{
    import std.algorithm : countUntil;
    import std.c.string : memcpy;

    struct _Info { string name; void*[] vtbl; void* classPtr; }

    static __gshared uint count = 0;
    static __gshared _Info[] infos;

    if (count == 0 && ti.name == "core.thread.Thread")
        return;

    if (repl is null)
    {
        count++;
        infos ~= _Info(ti.name.idup, ti.vtbl.dup, cptr);
    }
    else if (clear)
    {
        count = 0;
        infos.clear;
        return;
    }
    else
    {
        foreach(i; infos)
        {
            void* vtblPtr = null;
            size_t index = countUntil!"a.name == b"(repl.vtbls, i.name);

            if (index == -1) // No entry exists, need to dup the vtable
            {
                repl.vtbls ~= Vtbl(i.name, i.vtbl);
                index = repl.vtbls.length - 1;
            }

            vtblPtr = repl.vtbls[index].vtbl.ptr;

            assert(vtblPtr !is null, "Null vtbl pointer");

            // Now redirect the vtable pointer in the class
            memcpy(i.classPtr, &vtblPtr, (void*).sizeof);
        }
        count = 0;
        infos.clear;
    }
}

/**
* Generate the DLL header. This needs to be done dynamically, as we
* take the address of hookNewClass, and hard-code it in the DLL (!)
*/
string genHeader()
{
    void* prox = gc_getProxy();

    return
`
    import std.stdio, std.conv, std.range, std.algorithm, std.traits;
    import std.c.stdio, std.c.string, std.c.stdlib, std.c.windows.windows;
    import core.sys.windows.dll, core.runtime, core.memory;

    extern (C) void gc_setProxy(void*);

    extern(Windows) BOOL DllMain(HINSTANCE hInstance,DWORD ulReason,LPVOID lpvReserved)
    {
        final switch (ulReason)
        {
        case DLL_PROCESS_ATTACH:
            _REPL.fixUp();
            Runtime.initialize();
            break;
        case DLL_PROCESS_DETACH:
            break;
        case DLL_THREAD_ATTACH:
            break;
        case DLL_THREAD_DETACH:
            break;
        }
        return true;
    }

    struct _REPL
    {
        static struct Symbol
        {
            string name;
            string type;
            string current;
            string checkType;
            bool valid = false;
            void* addr;
        }

        static struct Vtbl
        {
            string name;
            void*[] vtbl;
        }

        static struct ReplContext
        {
            string filename = "replDll";
            string[] imports;
            string[] userTypes;
            _REPL.Symbol[] symbols;
            int[string] symbolSet;
            _REPL.Vtbl[] vtbls;
            void* gc;
            string[] includes;
        }

        static void fixUp()
        {
            import core.sys.windows.threadaux : getTEB;

            alias extern(Windows)
            void* fnRtlAllocateHeap(void* HeapHandle, uint Flags, size_t Size) nothrow;

            HANDLE hnd = GetModuleHandleA( "NTDLL" );
            assert( hnd, "cannot get module handle for ntdll" );

            fnRtlAllocateHeap* fnAlloc = cast(fnRtlAllocateHeap*) GetProcAddress( hnd, "RtlAllocateHeap" );

            auto teb = getTEB();
            void** peb = cast(void**) teb[12];
            void* heap = peb[6];

            auto sz = _tlsend - _tlsstart;
            void* _tlsdata = cast(void*) (*fnAlloc)( heap, 0xc0000, sz );

            core.stdc.string.memcpy( _tlsdata, _tlsstart, sz );

            auto tlsindex = 1;

            // create copy of tls pointer array
            void** array = cast(void**) (*fnAlloc)( heap, 0xc0000, (tlsindex + 1) * (void*).sizeof );

            if( tlsindex > 0 && teb[11] )
                core.stdc.string.memcpy( array, teb[11], tlsindex * (void*).sizeof);

            array[tlsindex] = _tlsdata;
            teb[11] = cast(void*) array;

            _tls_index ++;
        }

        static auto makeNew(string s, T)(ref _REPL.ReplContext repl, size_t index, T t = T.init)
        {
            import std.traits;
            enum assign = "auto _v = new "~s~";";
            static if (__traits(compiles, mixin("{"~assign~"}")))
            {
                mixin(assign);
                repl.symbols[index].addr = _v;
                return cast(T*)_v;
            }
            else
            {
                void* ptr;
                ptr = GC.calloc(T.sizeof);
                GC.disable();
                memcpy(ptr, &t, T.sizeof);
                GC.enable();

                repl.symbols[index].addr = ptr;
                return cast(T*)ptr;
            }
        }

        static string NewTypeof(string S, E)(lazy E expr)
        {
            import std.traits;
            alias ReturnType!expr RT;
            static if (__traits(compiles, mixin( "{" ~ RT.stringof ~ " _v;}")))
                return RT.stringof;
            else
                return "typeof(" ~ S ~ ")";
        }

        static T* getVar(T)(_REPL.ReplContext repl, size_t index)
        {
            return cast(T*)repl.symbols[index].addr;
        }

        static string exprResult(E)(lazy E expr)
        {
            static if (__traits(compiles, typeof(expr)))
            {
                static if (is(typeof(expr) == void))
                {
                    expr();
                    return "";
                }
                else
                {
                    auto temp = expr();
                    return temp.to!string;
                }
            }
        }

        static void hookNewClass(TypeInfo_Class ti, void* cptr)
        {
            alias extern(C) void function(TypeInfo_Class, void*, _REPL.ReplContext*, bool) cb;
            auto fp = cast(cb)(0x` ~ (&hookNewClass).to!string ~ `);
            fp(ti, cptr, null, false);
        }
    }

    extern (C) Object _d_newclass(const ClassInfo ci)
    {
        import core.memory, std.string, core.sys.windows.stacktrace;
        void* p;

        bool leak = false;
        auto curr = cast(ClassInfo)ci;

        while(curr)
        {
            if (curr == typeid(Throwable) || curr == typeid(StackTrace))
            {
                leak = true;
                break;
            }
            curr = curr.base;
        }


        if (leak)
        {
            p = malloc(ci.init.length); // let it leak for now
            (cast(byte*) p)[0 .. ci.init.length] = ci.init[];
            return cast(Object)p;
        }
        else
        {
            p = GC.malloc(ci.init.length,
                          GC.BlkAttr.FINALIZE | (ci.m_flags & 2 ? GC.BlkAttr.NO_SCAN : 0));

            (cast(byte*) p)[0 .. ci.init.length] = ci.init[];

            auto obj = cast(Object) p;
            _REPL.hookNewClass(typeid(obj), p);

            return obj;
        }
    }


`;
}

