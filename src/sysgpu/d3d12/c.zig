pub const c = @cImport({
    @cDefine("CINTERFACE", "");
    @cDefine("COBJMACROS", "");
    @cDefine("WIDL_using_Windows_Foundation", "");
    @cDefine("WIDL_using_Windows_Foundation_Collections", "");
    @cInclude("initguid.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi1_6.h");
    @cInclude("d3dcompiler.h");
    @cInclude("dxgidebug.h");
});
