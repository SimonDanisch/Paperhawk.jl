# Optional integration test with an already loaded Bonsai model:
# test_bonsai_scheduling(classifier) for the default process-backed classifier
function test_bonsai_scheduling(model)
    B=Paperhawk.BonsaiRunner
    @testset "Bonsai cooperative scheduling" begin
        s=B.session(model;kv_page=min(model.maxcontext,4096))
        try
            ids=B.encode(model.tokenizer,"Hallo")
            @test_throws ErrorException B.generate(s,ids;before_step=()->error("cancel before GPU work"))
            @test s.position==0
            positions=Int[]
            out=B.generate(s,ids;max_tokens=3,stop=(),prefill_chunk=1,
                before_step=()->push!(positions,s.position))
            @test length(out)==3
            @test positions==collect(0:length(ids)+1)
            @test s.position==length(ids)+2
        finally
            close(s)
        end
    end
end

function test_bonsai_scheduling(classifier::Paperhawk.ProcessClassifier)
    Paperhawk.Distributed.remotecall_fetch(classifier.pid,classifier.id,abspath(@__FILE__)) do id,file
        Core.eval(Main,:(using Paperhawk,Test))
        Base.include(Main,file)
        Base.invokelatest() do
            Main.test_bonsai_scheduling(Paperhawk.PROCESS_MODELS[id].model)
        end
        nothing
    end
end
