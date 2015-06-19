class PapersController < ApplicationController
  respond_to :json
  before_filter :require_user,   except: [ :state, :index, :versions ]
  before_filter :require_editor, only:   [ :destroy, :transition ]

  def index
    if current_user
      as_author
    else
      papers = []
      respond_with papers
    end
  end

  def show
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    ability = ability_with(current_user, paper)

    raise CanCan::AccessDenied if ability.cannot? :show, paper

    respond_with paper, serializer:FullPaperSerializer
  end

  def arxiv_details
    id = params[:id]
    existing = Paper.find_by_arxiv_id(id)

    if existing
      respond_with existing, serializer:ArxivSerializer

    else
      data = Arxiv.get(id)
      respond_with data
    end
  end

  def create
    paper = Paper.new_for_arxiv_id(params[:arxiv_id], submittor:current_user)
    authorize! :create, paper

    if paper.save
      render json:paper, status: :created, location:paper_review_url(paper), serializer:FullPaperSerializer
    else
      render json:aper.errors, status: :unprocessable_entity
    end
  end

  def update
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    ability = ability_with(current_user, paper)

    raise CanCan::AccessDenied if ability.cannot?(:update, paper)

    if paper.update_attributes(paper_params)
      render json:paper, location:paper_review_url(paper), serializer:FullPaperSerializer
    else
      render json:paper.errors, status: :unprocessable_entity
    end
  end

  def destroy
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    render_error(:unprocessable_entity) and return unless paper.can_destroy?

    ActiveRecord::Base.transaction do
      has_errors = false

      paper.all_versions.each do |p|
        p.destroy
        has_errors ||= p.errors.present?
      end

      if has_errors
        render_errors paper
        raise ActiveRecord::Rollback
      end

      render json:{}
    end

  end

  def state
    @paper = Paper.find_by_sha(params[:id])

    if @paper
      etag(params.inspect, @paper.state)
    else
      etag(params.inspect, "unknown")
    end

    render :layout => false
  end

  def transition
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    transition = params[:transition].to_sym

    authorize! transition, paper

    if paper.aasm.may_fire_event?(transition)
      paper.send("#{transition.to_s}!")
      render json:paper, location:paper_review_url(paper), serializer:FullPaperSerializer

    else
      render_errors(paper)
    end
  end

  def complete
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    authorize! :complete, paper

    if paper.mark_review_completed!(current_user)
      paper.assignments.reload
      render json:paper, location:paper_review_url(paper), serializer:FullPaperSerializer
    else
      render_errors(paper)
    end
  end

  def public
    paper = Paper.find_by_sha(params[:id])
    render_error(:not_found) and return unless paper
    authorize! :make_public, paper

    case request.method_symbol

      when :post, :delete
        public = request.method_symbol != :delete
        if paper.make_reviewer_public!(current_user, public)
          paper.assignments.reload
          render json:paper, location:paper_review_url(paper), serializer:FullPaperSerializer
        else
          render_errors(assignment)
        end

      else
        raise 'Unsupported method'

    end

  end

  def versions
    papers   = Paper.versions_for( params[:id] )
    render json:papers, each_serializer: BasicPaperSerializer
  end

  def check_for_update
    arxiv_id = params[:id]
    latest_paper = Paper.where(arxiv_id:arxiv_id).order(version: :desc).first

    render_error(:not_found)    and return unless latest_paper
    render_error(:forbidden)    and return unless latest_paper.submittor == current_user
    render_error(:conflict)     and return unless latest_paper.may_supercede?

    arxiv_doc = Arxiv.get(arxiv_id)

    render_error(:conflict, 'There is no new version of this document.') and return unless arxiv_doc.version > latest_paper.version

    new_paper = Paper.create_updated!(latest_paper, arxiv_doc)

    render json:new_paper, status: :created
  end

  def as_reviewer
    papers = current_user.papers_as_reviewer.active.with_state(params[:state])
    respond_with papers
  end

  def as_editor
    papers = current_user.papers_as_editor.active.with_state(params[:state])
    respond_with papers
  end

  def as_author
    papers = current_user.papers_as_submittor.active.with_state(params[:state])
    respond_with papers
  end

  def as_collaborator
    papers = current_user.papers_as_collaborator.active.with_state(params[:state])
    respond_with papers
  end

  private

  def paper_params
    params.require(:paper).permit(:title, :location)
  end

end
