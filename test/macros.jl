using AutoHashEquals
using ReTestItems
using Test

# this file specifically tests *unit* tests for the macros: `@testitem` and `@testsetup`
# so *not* the `runtests` functionality, which utilizes specific
# contrived packages/testfiles
n_passed(ts) = ts.n_passed
n_passed(ts::ReTestItems.TestItemResult) = n_passed(ts.testset)

# Mark `ReTestItems.runtests` as running, so that `@testitem`s don't run themselves.
function no_run(f)
    old = get(task_local_storage(), :__RE_TEST_RUNNING__, false)
    try
        task_local_storage()[:__RE_TEST_RUNNING__] = true
        return f()
    finally
        task_local_storage()[:__RE_TEST_RUNNING__] = old
    end
end

@testset "macros.jl" verbose=true begin

@testset "testsetup macro basic" begin
    ts = @testsetup module TS1
        x = 1
    end
    @test ts.name == :TS1
end

@testset "testitem macro basic" begin
    ti = no_run() do
        @testitem "TI1" begin
            @test 1 + 1 == 2
        end
    end
    @test ti.name == "TI1"
    @test ti.file isa String
    @test n_passed(ReTestItems.runtestitem(ti)) == 1
end

@testset "testitem with `tags`" begin
    ti2 = no_run() do
        @testitem "TI2" tags=[:foo] begin
            @test true
        end
    end
    @test ti2.tags == [:foo]
    @test n_passed(ReTestItems.runtestitem(ti2)) == 1
end

@testset "testitem with `retries`" begin
    ti = no_run() do
        @testitem "TI" retries=2 begin
            @test true
        end
    end
    @test ti.retries == 2
    @test n_passed(ReTestItems.runtestitem(ti)) == 1
end

@testset "testitem with macro import" begin
    # Test that `@testitem` correctly imports macros before expanding macros.
    ti3 = no_run() do
            @testitem "macro-import" begin
            # Test with something that won't be imported in Main
            # i.e. not Base, Test, or TestsInSrc (i.e. this package)
            # Let's use a small package with a widely-used macro.
            # We merely want to check that this testitem runs without hitting
            # a `UndefVarError: @auto_hash_equals not defined`.
            using AutoHashEquals: @auto_hash_equals
            @auto_hash_equals mutable struct MacroTest
                x
            end
            @test MacroTest(1) isa MacroTest
        end
    end
    @test n_passed(ReTestItems.runtestitem(ti3)) == 1
end

@testset "testitem with `setup`" begin
    ts1 = @testsetup module FooSetup
        x = 1
        const y = 2
        export y
    end
    # test that imported macro usage also works in testsetup
    ts2 = @testsetup module FooSetup2
        using AutoHashEquals: @auto_hash_equals
        @auto_hash_equals struct Foo
            x::Int
        end
        @assert Foo(1) isa Foo
    end
    ti4 = no_run() do
        @testitem "Foo" setup=[FooSetup, FooSetup2] begin
            @test FooSetup.x == 1
            @test y == 2
            @test FooSetup2.Foo(1) isa FooSetup2.Foo
        end
    end
    @test ti4.setups == [:FooSetup, :FooSetup2]
    @test n_passed(ReTestItems.runtestitem(ti4)) == 3
end

@testset "testsetup and testitem with includes" begin
    ts = @testsetup module FooSetup3
        include("_testsetupinclude.jl")
    end
    ti5 = no_run() do
        @testitem "Foo3" setup=[FooSetup3] begin
            include("_testiteminclude.jl")
        end
    end
    @test n_passed(ReTestItems.runtestitem(ti5)) == 2
end

@testset "missing testsetup" begin
    ti6 = no_run() do
        @testitem "Foo4" setup=[NonExistentSetup] begin
            @test 1 + 1 == 2
        end
    end
    ts = ReTestItems.runtestitem(ti6; finish_test=false)
    @test ts.testset.results[1] isa Test.Error
end

@testset "testitem with duplicate keywords" begin
    # can only check for text of the error message in Julia v1.8+
    expected = VERSION < v"1.8" ? Exception : "duplicate keyword"
    @test_throws expected (
        @eval @testitem "Bad" tags=[:tag1] tags=[:tags2] begin
            @test true
        end
    )
end

@testset "can identity if in a `@testitem`" begin
    @testitem "testitem active" begin
        @test get(task_local_storage(), :__TESTITEM_ACTIVE__, false)
    end
    @test !get(task_local_storage(), :__TESTITEM_ACTIVE__, false)
end

@testset "testitem macro runs immediately outside `runtests`" begin
    # Should run and return `nothing`
    @test nothing == @testitem "run" begin; @test true; end
    # Double-check it runs by looking for the START/DONE messages.
    # The START/DONE messages are always logged to DEFAULT_STDOUT, so we need to catch that.
    old = ReTestItems.DEFAULT_STDOUT[]
    try
        io = IOBuffer()
        ReTestItems.DEFAULT_STDOUT[] = io
        @testitem "run" begin
            @test true
        end
        output = String(take!(io))
        @test contains(output, r"START\s*test item \"run\"")
        @test contains(output, r"DONE\s*test item \"run\"")
    finally
        ReTestItems.DEFAULT_STDOUT[] = old
    end
    @testset "`runtestitem` default behaviour" begin
        # When running an individual test-item by itself we default to verbose output
        # i.e. eager logs and full results table.
        using IOCapture
        # run `testset_func` as if not already inside a testset, so it prints results immediately.
        function toplevel_testset(testset_func)
            old = get(task_local_storage(), :__BASETESTNEXT__, nothing)
            try
                if old !== nothing
                    delete!(task_local_storage(), :__BASETESTNEXT__)
                end
                testset_func()
            finally
                if old !== nothing
                    task_local_storage()[:__BASETESTNEXT__] = old
                end
            end
        end
        c = IOCapture.capture() do
            toplevel_testset() do
                @testitem "comparisons" begin
                    @testset "min" begin
                        @info "test 1"
                        @test min(1, 2) == 1
                    end
                    @testset "max" begin
                        @info "test 2"
                        @test max(1, 2) == 2
                    end
                end
            end
        end
        @test contains(
            c.output,
            r"""
            \[ Info: test 1
            \[ Info: test 2
            Test Summary: \| Pass  Total  Time
            comparisons   \|    2      2  \d*.\ds
              min         \|    1      1  \d*.\ds
              max         \|    1      1  \d*.\ds
            """
        )
    end
end

#=
NOTE:
    These tests are disabled as we stopped using anonymous modules;
    there were issues when tests tried serialize/deserialize with things defined in
    an anonymous module.

# Make these globals so that our testitem can access it via Main.was_finalized
was_finalized = Threads.Atomic{Bool}(false)
# Define the struct outside the testitem, since otherwise the Method Table prevents the
# testitem module from being GC'd. See: https://github.com/JuliaLang/julia/issues/48711
mutable struct MyTempType
    v::Int
    function MyTempType(v)
        x = new(v)
        Core.println("I made a new ", pointer_from_objref(x))
        finalizer(x) do obj
            Core.println("I am destroyed!")
            Core.println(pointer_from_objref(obj))
            Main.was_finalized[] = true
        end
        return x
    end
end

# disabled for now since there are issues w/ eval-ing
# testitems into anonymous modules
# @testset "testitems are GC'd correctly" begin
#     ti7 = @testitem "Foo7" begin
#         x = Main.MyTempType(1)
#         x = nothing
#         GC.gc()
#         GC.gc()
#         @test Main.was_finalized[] = true

#         # Now reset this, and keep a "global" object around
#         Main.was_finalized[] = false
#         x2 = Main.MyTempType(1)
#         @test x2.v == 1

#         # Then return. After running GC.gc() _outside_ the testitem, we should
#         # free the entire testitem, including the global objects its holding onto,
#         # including `x2`, which should set was_finalized[] back to true. :)
#     end
#     ts = ReTestItems.runtestitem(ti7; finish_test=true)
#     @test n_passed(ts) == 2

#     @test Main.was_finalized[] == false
#     ts = ti7 = nothing
#     GC.gc()
#     GC.gc()
#     @test Main.was_finalized[] == true
# end
=#

end # macros.jl testset
